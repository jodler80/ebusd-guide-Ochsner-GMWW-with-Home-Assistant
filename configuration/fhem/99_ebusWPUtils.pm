##############################################################################
#
#  99_ebusWPUtils.pm - Schreibzugriff FHEM -> ebusd -> Ochsner-WP (Schutzebene B)
#
#  Aufruf aus der setList von ebusWP:   {ebusWP_Set($NAME,$EVENT)}
#  $EVENT = "<Key> <Wert>", z. B. "HKR2_Betriebswahl Automatik"
#
#  Schutz (zusaetzlich zu ebusd-Whitelist/Wertelisten/ACL, siehe
#  docs/ochsner_tem_protocol.md section 10 and docs/fhem_integration_example.md):
#   - feste Whitelist mit Pruefung von Bereich, Schritt und Enum je Key
#   - Not-Aus:      attr ebusWP ebusSchreibsperre 1
#   - Warteschlange, global >= 10 s Abstand zwischen zwei Buszugriffen
#   - Tageslimit je Key, gleicher Wert wie Ist -> nicht senden
#   - wartender Auftrag desselben Keys wird durch den neuesten Wert ersetzt,
#     Warteschlange max. 10 Auftraege (Rest verworfen, Log Level 1)
#   - Ausfuehrung im Kindprozess (BlockingCall): FHEM blockiert nicht
#   - je Befehl ein eigenes TCP-Paket (ebusd liest mehrere Zeilen sonst als einen Befehl)
#   - 12 s nach dem Schreiben Ruecklesen und Vergleich
#  Ergebnis: Readings Schreib_Status / Schreib_Letzter an ebusWP + Log (Level 3)
#
##############################################################################
package main;
use strict;
use warnings;
use POSIX qw(strftime);
use IO::Socket::INET;
use IO::Select;
use Blocking;

my $EBUSWP_SECRET  = "/opt/fhem/.ebusd_secret";   # ACL-Benutzer "fhem" (siehe /etc/ebusd/acl)
my $EBUSWP_PAUSE   = 10;                          # s zwischen zwei Buszugriffen
my $EBUSWP_TAGESMAX = 20;                         # Schreibvorgaenge je Key und Tag
my $EBUSWP_QUEUEMAX = 10;                         # max. wartende Auftraege (Schutz gegen Schleifen)

# Whitelist: Key (setList-Name) => ebusd-Nachricht + Pruefung
my %EBUSWP_W = (
  HKR1_Betriebswahl => { msg => 'Betriebswahl.Heizkreis.03.050', enum => [qw(Standbybetrieb Automatik Handbetrieb_Heizen)] },
  HKR2_Betriebswahl => { msg => 'Betriebswahl.HKR2.03.050',      enum => [qw(Standbybetrieb Automatik Handbetrieb_Heizen)] },
  HKR1_Handsoll     => { msg => 'Solltemp.Handbetrieb.HKR1.07.009', min => 10, max => 34, schritt => 0.5, fmt => '%.1f' },
  HKR2_Handsoll     => { msg => 'Solltemp.Handbetrieb.HKR2.07.009', min => 10, max => 34, schritt => 0.5, fmt => '%.1f' },
  WW_Sollwert       => { msg => 'Warmwassertemp.SOLL.05.051',     min => 10, max => 60, schritt => 1,   fmt => '%d' },
  WW_Betriebswahl   => { msg => 'Betriebswahl.Warmwasser.05.050', enum => [qw(Keine_Ladung Automatik Normaltemperatur)] },
  WP_Uhrzeit_sync   => { msg => 'Waermepumpe.Uhrzeit.02.072',     uhr => 1 },
);

sub ebusWPUtils_Initialize($) { }

# --- Einstieg aus der setList -------------------------------------------------
sub ebusWP_Set($$) {
  my ($name, $event) = @_;
  my $hash = $defs{$name};
  return undef if(!$hash);
  my ($key, $wert) = split(/\s+/, $event // "", 2);
  $wert = "" if(!defined $wert);
  $wert =~ s/^\s+|\s+$//g;
  my $d = $EBUSWP_W{$key // ""};

  return ebusWP_Status($hash, "abgewiesen: $key unbekannt") if(!$d);
  return ebusWP_Status($hash, "abgewiesen: Schreibsperre aktiv")
    if(AttrVal($name, "ebusSchreibsperre", 0) eq "1");

  my $senden;
  if($d->{enum}) {
    return ebusWP_Status($hash, "abgewiesen: $key $wert nicht erlaubt")
      if(!grep { $_ eq $wert } @{$d->{enum}});
    $senden = $wert;
  } elsif($d->{uhr}) {
    $senden = "sync";                      # Pruefung und Zeitpunkt im Kindprozess
  } else {
    $wert =~ s/,/./;
    return ebusWP_Status($hash, "abgewiesen: $key $wert keine Zahl")
      if($wert !~ /^\d{1,2}(\.\d)?$/);
    return ebusWP_Status($hash, "abgewiesen: $key $wert ausserhalb $d->{min}-$d->{max}")
      if($wert < $d->{min} || $wert > $d->{max});
    my $n = $wert / $d->{schritt};
    return ebusWP_Status($hash, "abgewiesen: $key $wert nicht im Raster $d->{schritt}")
      if(abs($n - int($n + 0.5)) > 1e-6);
    $senden = sprintf($d->{fmt}, $wert);
  }

  if(!$d->{uhr}) {
    my $ist = ReadingsVal($name, $d->{msg}, "");
    return ebusWP_Status($hash, "unveraendert: $key ist bereits $ist")
      if($ist ne "" && ($ist eq $senden || ($ist =~ /^-?[\d.]+$/ && $senden =~ /^-?[\d.]+$/ && $ist == $senden)));
  }

  my $heute = strftime("%Y-%m-%d", localtime);
  my $z = $hash->{helper}{ebusW}{zaehler}{$key} //= { tag => $heute, n => 0 };
  ($z->{tag}, $z->{n}) = ($heute, 0) if($z->{tag} ne $heute);
  return ebusWP_Status($hash, "abgewiesen: Tageslimit $EBUSWP_TAGESMAX fuer $key erreicht")
    if($z->{n} >= $EBUSWP_TAGESMAX);
  $z->{n}++;

  my $q = $hash->{helper}{ebusW}{queue} //= [];
  my ($alt) = grep { $_->{key} eq $key } @{$q};
  if($alt) {                               # wartender Auftrag desselben Keys: nur den neuesten Wert behalten
    $z->{n}--;                             # ersetzt -> zaehlt nicht doppelt
    my $vorher = $alt->{wert};
    $alt->{wert} = $senden;
    ebusWP_Status($hash, "ersetzt: $key $vorher -> $senden (" . scalar(@{$q}) . " in Warteschlange)");
  } else {
    if(@{$q} >= $EBUSWP_QUEUEMAX) {
      $z->{n}--;
      Log3 $name, 1, "ebusWP Schreiben: Warteschlange voll ($EBUSWP_QUEUEMAX) - $key $senden verworfen";
      return ebusWP_Status($hash, "FEHLER: Warteschlange voll ($EBUSWP_QUEUEMAX) - $key $senden verworfen");
    }
    push @{$q}, { key => $key, msg => $d->{msg}, wert => $senden };
    ebusWP_Status($hash, "eingereiht: $key $senden (" . scalar(@{$q}) . " in Warteschlange)");
  }
  ebusWP_Next($hash);
  return undef;                            # nichts per MQTT publizieren
}

sub ebusWP_Status($$) {
  my ($hash, $txt) = @_;
  readingsSingleUpdate($hash, "Schreib_Status", $txt, 1);
  Log3 $hash->{NAME}, 3, "ebusWP Schreiben: $txt";
  return undef;
}

# --- Warteschlange ------------------------------------------------------------
sub ebusWP_Next($) {
  my ($hash) = @_;
  my $h = $hash->{helper}{ebusW};
  return if($h->{laeuft} || !$h->{queue} || !@{$h->{queue}});
  my $warten = ($h->{letzter} // 0) + $EBUSWP_PAUSE - gettimeofday();
  if($warten > 0) {
    RemoveInternalTimer($hash, "ebusWP_Next");
    InternalTimer(gettimeofday() + $warten, "ebusWP_Next", $hash, 0);
    return;
  }
  my $job = shift @{$h->{queue}};
  $h->{laeuft} = 1;
  $h->{pid} = BlockingCall("ebusWP_Kind", join("|", $hash->{NAME}, $job->{key}, $job->{msg}, $job->{wert}),
                           "ebusWP_Fertig", 150, "ebusWP_Abbruch", $hash);
}

# --- Kindprozess: ebusd per TCP ---------------------------------------------------
sub ebusWP_Befehl($$) {
  my ($sock, $cmd) = @_;
  print $sock "$cmd\n";
  my ($antwort, $sel) = ("", IO::Select->new($sock));
  while($sel->can_read(5)) {
    my $buf;
    last if(!sysread($sock, $buf, 4096));
    $antwort .= $buf;
    last if($antwort =~ /\n\n$/);          # ebusd beendet jede Antwort mit Leerzeile
  }
  $antwort =~ s/\s+$//;
  return $antwort eq "" ? "ERR: keine Antwort" : $antwort;
}

sub ebusWP_Kind($) {
  my ($arg) = @_;
  my ($name, $key, $msg, $wert) = split(/\|/, $arg);
  my $fehler = sub { return join("|", $name, $key, $wert, "Fehler", $_[0], "") };

  open(my $fh, '<', $EBUSWP_SECRET) or return $fehler->("Geheimnis nicht lesbar");
  my $secret = <$fh>; close($fh);
  chomp($secret);
  my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => 8888, Proto => "tcp", Timeout => 5)
    or return $fehler->("ebusd nicht erreichbar");

  if($wert eq "sync") {                    # Uhrzeit: nur bei > 2 min Abweichung, nie um Mitternacht
    my $wp = ebusWP_Befehl($sock, "read -f -c ochsner $msg");
    return $fehler->("Uhrzeit nicht lesbar: $wp") if($wp !~ /^(\d\d):(\d\d)$/);
    my @t = localtime;
    my $diff = ($1 * 60 + $2) - ($t[2] * 60 + $t[1]);
    $diff += 1440 if($diff < -720); $diff -= 1440 if($diff > 720);
    return join("|", $name, $key, "", "unnoetig", "Abweichung $diff min", $wp) if(abs($diff) <= 2);
    my $hm = $t[2] * 60 + $t[1];
    return $fehler->("Sperrzeit 23:45-00:15") if($hm >= 23*60+44 || $hm <= 15);
    sleep(12);                             # Abstand zum Lesen
    @t = localtime;
    sleep(60 - $t[0]) if($t[0] > 0);       # auf Minutenbeginn warten
    $wert = strftime("%H:%M", localtime);
  }

  my $auth = ebusWP_Befehl($sock, "auth fhem $secret");
  return $fehler->("auth: $auth") if($auth ne "done");
  my $w = ebusWP_Befehl($sock, "write -c ochsner $msg $wert");
  return $fehler->("write: $w") if($w ne "done");
  sleep(12);                               # Pausenregel vor dem Ruecklesen
  my $r = ebusWP_Befehl($sock, "read -f -c ochsner $msg");
  close($sock);
  my $ok = ($r eq $wert || ($r =~ /^-?[\d.]+$/ && $wert =~ /^-?[\d.]+$/ && $r == $wert)) ? "ok" : "Abweichung";
  return join("|", $name, $key, $wert, $ok, "", $r);
}

# --- Ergebnis im Hauptprozess ----------------------------------------------------
sub ebusWP_Fertig($) {
  my ($ret) = @_;
  my ($name, $key, $wert, $ergebnis, $info, $rueck) = split(/\|/, $ret // "", 6);
  my $hash = $defs{$name // ""};
  return if(!$hash);
  my $h = $hash->{helper}{ebusW};
  delete $h->{laeuft}; delete $h->{pid};
  $h->{letzter} = gettimeofday();
  my $txt = $ergebnis eq "ok"       ? "ok: $key = $wert (rueckgelesen $rueck)"
          : $ergebnis eq "unnoetig" ? "unveraendert: $key $info (WP $rueck)"
          : "FEHLER: $key $wert - " . ($info || "Ruecklesen $rueck");
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "Schreib_Status", $txt);
  readingsBulkUpdate($hash, "Schreib_Letzter", strftime("%Y-%m-%d %H:%M:%S", localtime) . " $key $wert $ergebnis")
    if($ergebnis ne "unnoetig");
  readingsEndUpdate($hash, 1);
  Log3 $name, ($ergebnis eq "ok" || $ergebnis eq "unnoetig") ? 3 : 1, "ebusWP Schreiben: $txt";
  ebusWP_Next($hash);
}

sub ebusWP_Abbruch($) {
  my ($hash) = @_;
  my $h = $hash->{helper}{ebusW};
  delete $h->{laeuft}; delete $h->{pid};
  $h->{letzter} = gettimeofday();
  ebusWP_Status($hash, "FEHLER: Zeitueberschreitung beim Schreiben");
  ebusWP_Next($hash);
}

1;
