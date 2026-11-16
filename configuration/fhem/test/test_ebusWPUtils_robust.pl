use strict;
use warnings;
use utf8;
use Test::More;
our @WARN; local $SIG{__WARN__} = sub { push @WARN, $_[0] unless $_[0] =~ /redefined/ };
require "./fhem_stub.pl"; require "./Blocking.pm"; require "../99_ebusWPUtils.pm";

# Hilfsfunktionen
sub setup {
  stub_reset();
  @main::STUB_BLOCKING=();
  stub_device("ebusWP", {"Solltemp.Handbetrieb.HKR1.07.009"=>"20.0","Solltemp.Handbetrieb.HKR2.07.009"=>"20.0",
   "Warmwassertemp.SOLL.05.051"=>"43.0","Betriebswahl.Heizkreis.03.050"=>"Automatik","Betriebswahl.HKR2.03.050"=>"Automatik",
   "Betriebswahl.Warmwasser.05.050"=>"Automatik"});
}

sub pruefe_auftraege {
  my ($fall) = @_;
  my @eintraege;
  
  # Aus @main::STUB_BLOCKING
  push @eintraege, $_->{arg} for @main::STUB_BLOCKING;
  
  # Aus der Warteschlange
  if ($main::defs{"ebusWP"} && $main::defs{"ebusWP"}{helper} && $main::defs{"ebusWP"}{helper}{ebusW} && ref($main::defs{"ebusWP"}{helper}{ebusW}{queue}) eq 'ARRAY') {
      my $queue = $main::defs{"ebusWP"}{helper}{ebusW}{queue};
      for my $job (@$queue) {
          my $arg = "ebusWP|" . ($job->{key} // "") . "|" . ($job->{msg} // "") . "|" . ($job->{wert} // "");
          push @eintraege, $arg;
      }
  }
  
  # Muster
  my @muster = (
      qr/^ebusWP\|HKR[12]_Betriebswahl\|[^|]+\|(Standbybetrieb|Automatik|Handbetrieb_Heizen)$/,
      qr/^ebusWP\|WW_Betriebswahl\|[^|]+\|(Keine_Ladung|Automatik|Normaltemperatur)$/,
      qr/^ebusWP\|HKR[12]_Handsoll\|[^|]+\|([0-9]+\.[0-9])$/,
      qr/^ebusWP\|WW_Sollwert\|[^|]+\|([0-9]+)$/,
      qr/^ebusWP\|WP_Uhrzeit_sync\|[^|]+\|sync$/,
  );
  
  for my $e (@eintraege) {
      my $ok = 0;
      for my $m (@muster) {
          if ($e =~ $m) {
              $ok = 1;
              # Zusätzliche Checks für Zahlenwerte
              if ($e =~ m/^ebusWP\|HKR[12]_Handsoll\|[^|]+\|([0-9]+\.[0-9])$/) {
                  my $val = $1;
                  if ($val < 10 || $val > 34) {
                      fail("$fall: ungueltiger Auftrag $e (Bereich)");
                      $ok = 0;
                  } elsif (($val * 2) % 1 != 0) {
                      fail("$fall: ungueltiger Auftrag $e (Schritt)");
                      $ok = 0;
                  }
              } elsif ($e =~ m/^ebusWP\|WW_Sollwert\|[^|]+\|([0-9]+)$/) {
                  my $val = $1;
                  if ($val < 10 || $val > 60) {
                      fail("$fall: ungueltiger Auftrag $e (Bereich)");
                      $ok = 0;
                  }
              }
              last if ($ok);
          }
      }
      fail("$fall: ungueltiger Auftrag $e") if (!$ok);
  }
}

# A) Handsoll
my @handsoll_faelle = (
    ["HKR1_Handsoll hoch!", 0],
    ["HKR1_Handsoll ", 0],
    ["HKR1_Handsoll 22,5", 1],
    ["HKR1_Handsoll 22.5°C", 0],
    ["HKR1_Handsoll 22.5 °C", 0],
    ["HKR1_Handsoll 1e3", 0],
    ["HKR1_Handsoll 0x20", 0],
    ["HKR1_Handsoll NaN", 0],
    ["HKR1_Handsoll inf", 0],
    ["HKR1_Handsoll -5", 0],
    ["HKR1_Handsoll 22..5", 0],
    ["HKR1_Handsoll 22.55", 0],
    ["HKR1_Handsoll 999999999999", 0],
    ["HKR1_Handsoll \x{663}\x{662}", 0],
    ["HKR1_Handsoll 22;shutdown", 0],
    ["HKR1_Handsoll 22|x", 0],
    ["HKR1_Handsoll 22\n23", 0],
    ["HKR1_Handsoll 34.5", 0],
    ["HKR1_Handsoll 9.5", 0],
);

for my $f (@handsoll_faelle) {
    my ($input, $erwartet_auftrag) = @$f;
    setup();
    eval { ebusWP_Set("ebusWP", $input) };
    ok(!$@, "$input: kein die");
    
    if ($erwartet_auftrag) {
        is(scalar(@main::STUB_BLOCKING), 1, "$input: ein Auftrag");
        if (scalar(@main::STUB_BLOCKING) == 1) {
            is($main::STUB_BLOCKING[0]{arg}, "ebusWP|HKR1_Handsoll|Solltemp.Handbetrieb.HKR1.07.009|22.5", "$input: korrektes Argument");
        }
    } else {
        is(scalar(@main::STUB_BLOCKING), 0, "$input: kein Auftrag");
        my $status = R("ebusWP", "Schreib_Status");
        like($status // "", qr/^abgewiesen/, "$input: Status abgewiesen");
    }
    pruefe_auftraege($input);
}

# B) Enum
my @enum_faelle = (
    ["HKR1_Betriebswahl automatik", 0],
    ["HKR1_Betriebswahl Auto", 0],
    ["HKR1_Betriebswahl Automatik;shutdown", 0],
    ["HKR1_Betriebswahl 1", 0],
    ["WW_Betriebswahl Normaltemperatur|x", 0],
    ["HKR2_Betriebswahl ", 0],
);

for my $f (@enum_faelle) {
    my ($input, $erwartet_auftrag) = @$f;
    setup();
    eval { ebusWP_Set("ebusWP", $input) };
    ok(!$@, "$input: kein die");
    
    is(scalar(@main::STUB_BLOCKING), 0, "$input: kein Auftrag");
    my $status = R("ebusWP", "Schreib_Status");
    like($status // "", qr/^abgewiesen/, "$input: Status abgewiesen");
    pruefe_auftraege($input);
}

# C) WW_Sollwert
my @ww_faelle = (
    ["WW_Sollwert 60.5", 0],
    ["WW_Sollwert 61", 0],
    ["WW_Sollwert 9", 0],
    ["WW_Sollwert 50,0", 1],
);

for my $f (@ww_faelle) {
    my ($input, $erwartet_auftrag) = @$f;
    setup();
    eval { ebusWP_Set("ebusWP", $input) };
    ok(!$@, "$input: kein die");
    
    if ($erwartet_auftrag) {
        is(scalar(@main::STUB_BLOCKING), 1, "$input: ein Auftrag");
        if (scalar(@main::STUB_BLOCKING) == 1) {
            is($main::STUB_BLOCKING[0]{arg}, "ebusWP|WW_Sollwert|Warmwassertemp.SOLL.05.051|50", "$input: korrektes Argument");
        }
    } else {
        is(scalar(@main::STUB_BLOCKING), 0, "$input: kein Auftrag");
    }
    pruefe_auftraege($input);
}

# D) Unbekannt/leer
my @unbekannt_faelle = (
    [undef, 1],
    ["", 1],
    ["   ", 1],
    ["Foo 1", 1],
    ["HKR1_Handsoll", 1],
    ["|||", 1],
    ["WP_Uhrzeit_sync jetzt", 1],
);

for my $f (@unbekannt_faelle) {
    my ($input, $erlaubt) = @$f;
    setup();
    eval { ebusWP_Set("ebusWP", $input) };
    ok(!$@, ($input // "undef") . ": kein die");
    
    # Alle sollen gültig sein (kein Die) und pruefe_auftraege soll keine Fehler melden
    # "WP_Uhrzeit_sync jetzt" darf einen Auftrag mit Wert "sync" erzeugen
    if ($input && $input =~ /WP_Uhrzeit_sync/) {
        # Prüfen, ob ein Auftrag in Queue oder Blocking ist
        my $gefunden = 0;
        if (scalar(@main::STUB_BLOCKING) > 0 && $main::STUB_BLOCKING[0]{arg} =~ /sync$/) {
            $gefunden = 1;
        }
        if ($main::defs{"ebusWP"}{helper}{ebusW}{queue} && scalar(@{$main::defs{"ebusWP"}{helper}{ebusW}{queue}}) > 0) {
            for my $job (@{$main::defs{"ebusWP"}{helper}{ebusW}{queue}}) {
                if ($job->{wert} eq "sync") {
                    $gefunden = 1;
                }
            }
        }
        # Es darf einen Auftrag geben, muss aber nicht zwingend sofort ausgeführt sein
        # Aber wenn, dann muss er gültig sein
    }
    
    pruefe_auftraege($input // "undef");
}

# E) Flut
setup();
# 30 verschiedene gültige Aufträge: HKR1_Handsoll 10.0, 10.5, ..., 24.5
for my $i (0..29) {
    my $wert = 10.0 + $i * 0.5;
    $wert = sprintf("%.1f", $wert);
    eval { ebusWP_Set("ebusWP", "HKR1_Handsoll $wert") };
    ok(!$@, "Flut $i: kein die");
}
ok(1, "Flut: kein die (gesamtes Batch)");

# Warteschlange prüfen
my $queue_ref = $main::defs{"ebusWP"}{helper}{ebusW}{queue};
my $queue_len = ($queue_ref ? scalar(@$queue_ref) : 0);
cmp_ok($queue_len, "<=", 10, "Flut: Warteschlange <= 10");
cmp_ok(scalar(@main::STUB_BLOCKING), "<=", 1, "Flut: max. 1 gestarteter BlockingCall");
pruefe_auftraege("Flut");

# F) Schreibsperre
setup();
$main::attr{"ebusWP"}{ebusSchreibsperre} = 1;
eval { ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5") };
ok(!$@, "Schreibsperre: kein die");
is(scalar(@main::STUB_BLOCKING), 0, "Schreibsperre: kein Auftrag");
my $status = R("ebusWP", "Schreib_Status");
like($status // "", qr/Schreibsperre/, "Schreibsperre: Status enthält Schreibsperre");
pruefe_auftraege("Schreibsperre");

# Endprüfung
is(scalar(grep { /uninitialized|isn't numeric/ } @WARN), 0, "keine Perl-Warnungen") or diag(join("",@WARN));
done_testing();
