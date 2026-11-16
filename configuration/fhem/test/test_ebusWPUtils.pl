# test_ebusWPUtils.pl - Regressionstests fuer 99_ebusWPUtils.pm (Schreibweg FHEM -> ebusd)
# Aufruf in test/:  perl -I . test_ebusWPUtils.pl [Moduldatei]
#   Standard: ../99_ebusWPUtils.pm
# Der Kindprozess (ebusd-TCP) wird nicht ausgefuehrt: Blocking.pm (Test-Ersatz) protokolliert BlockingCall;
# Fertig/Abbruch werden im Test von Hand ausgeloest.
use strict;
use warnings;
use Test::More;
our @WARN; local $SIG{__WARN__} = sub { push @WARN, $_[0] unless $_[0] =~ /redefined/ };
require "./fhem_stub.pl";
require "./Blocking.pm";
my $modul = shift // "../99_ebusWPUtils.pm";
require $modul;
diag("Modul: $modul");

sub setup {
  stub_reset(); @main::STUB_BLOCKING = (); $main::STUB_BLOCKING_FAIL = 0;
  stub_device("ebusWP", { "Solltemp.Handbetrieb.HKR1.07.009" => "20.0", "Betriebswahl.Heizkreis.03.050" => "Automatik",
                          "Warmwassertemp.SOLL.05.051" => "43.0" });
  return $main::defs{"ebusWP"};
}
sub status { return R("ebusWP", "Schreib_Status") // ""; }
sub calls  { return scalar @main::STUB_BLOCKING; }
# Uhr um $s Sekunden weiterstellen und dabei faellige Timer ausfuehren
sub warte  { my ($s) = @_; my $bis = $main::STUB_NOW + $s; stub_fire_timers($bis); $main::STUB_NOW = $bis; }

# 1. Normaler Ablauf: erster Auftrag sofort, zweiter nach >= 10 s Pause
{
  my $h = setup();
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  is(calls(), 1, "1: erster Auftrag startet sofort");
  is($main::STUB_BLOCKING[0]{arg}, "ebusWP|HKR1_Handsoll|Solltemp.Handbetrieb.HKR1.07.009|25.5", "1: Auftrag an Kindprozess korrekt");
  ebusWP_Set("ebusWP", "HKR1_Betriebswahl Handbetrieb_Heizen");
  like(status(), qr/^eingereiht: HKR1_Betriebswahl/, "1: zweiter Auftrag eingereiht");
  ebusWP_Fertig("ebusWP|HKR1_Handsoll|25.5|ok||25.5");
  like(status(), qr/^ok: HKR1_Handsoll = 25.5/, "1: Fertig meldet ok");
  is(calls(), 1, "1: zweiter Auftrag wartet die Pause ab");
  warte(9);
  is(calls(), 1, "1: nach 9 s noch nicht gestartet");
  warte(2);
  is(calls(), 2, "1: nach >= 10 s gestartet");
  like($main::STUB_BLOCKING[1]{arg}, qr/\|HKR1_Betriebswahl\|Betriebswahl\.Heizkreis\.03\.050\|Handbetrieb_Heizen$/, "1: zweiter Auftrag korrekt");
}

# 2. Pruefungen unveraendert
{
  setup();
  ebusWP_Set("ebusWP", "HKR1_Handsoll 20");
  like(status(), qr/^unveraendert/, "2: gleicher Wert -> unveraendert");
  is(calls(), 0, "2: kein Buszugriff");
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.3");
  like(status(), qr/nicht im Raster/, "2: Raster");
  ebusWP_Set("ebusWP", "HKR1_Handsoll 35");
  like(status(), qr/ausserhalb/, "2: Bereich");
  ebusWP_Set("ebusWP", "HKR1_Handsoll hoch!");
  like(status(), qr/keine Zahl/, "2: Text");
  ebusWP_Set("ebusWP", "HKR1_Betriebswahl Foo");
  like(status(), qr/nicht erlaubt/, "2: Enum");
  $main::attr{"ebusWP"}{ebusSchreibsperre} = 1;
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  like(status(), qr/Schreibsperre/, "2: Schreibsperre");
  is(calls(), 0, "2: nie ein Buszugriff");
}

# 3. Zeitueberschreitung (Abbruch) -> naechster Auftrag laeuft
{
  my $h = setup();
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  ebusWP_Set("ebusWP", "WW_Sollwert 50");
  ebusWP_Abbruch($h);
  like(status(), qr/Zeitueberschreitung/, "3: Abbruch gemeldet");
  warte(10);
  is(calls(), 2, "3: naechster Auftrag nach Abbruch gestartet");
}

# 4. BlockingCall startet nicht (Fork fehlgeschlagen) -> Warteschlange darf nicht haengen
{
  my $h = setup();
  $main::STUB_BLOCKING_FAIL = 1;
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  $main::STUB_BLOCKING_FAIL = 0;
  ok(!$h->{helper}{ebusW}{laeuft}, "4: Merker laeuft nach Fehlstart zurueckgesetzt");
  like(status(), qr/^FEHLER: Kindprozess nicht gestartet/, "4: Fehlstart gemeldet");
  $main::STUB_NOW += 3600;
  ebusWP_Set("ebusWP", "HKR1_Betriebswahl Handbetrieb_Heizen");
  warte(10);
  is(calls(), 2, "4: spaeterer Auftrag wird ausgefuehrt (vorher: haengt dauerhaft)");
}

# 5. Keine Rueckmeldung (Fertig/Abbruch kommen nie) -> Waechter gibt nach 200 s frei
{
  my $h = setup();
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  ebusWP_Set("ebusWP", "WW_Sollwert 50");
  warte(150);
  is(calls(), 1, "5: nach 150 s noch blockiert");
  warte(60);
  like(join("\n", @main::STUB_LOG), qr/keine Rueckmeldung/, "5: Waechter hat ausgeloest");
  warte(10);
  is(calls(), 2, "5: wartender Auftrag laeuft nach Waechter");
}

# 7. reload waehrend laufendem Auftrag (Merker laeuft ohne seit): nicht sofort freigeben, erst nach 200 s
{
  my $h = setup();
  ebusWP_Set("ebusWP", "HKR1_Handsoll 25.5");
  delete $h->{helper}{ebusW}{seit};                 # Zustand wie nach reload der alten Modulfassung
  ebusWP_Set("ebusWP", "WW_Sollwert 50");
  is(calls(), 1, "7: kein zweiter Kindprozess direkt nach reload");
  warte(150);
  is(calls(), 1, "7: auch nach 150 s nicht (Kindprozess koennte noch schreiben)");
  ebusWP_Set("ebusWP", "HKR2_Handsoll 22.0");
  warte(60); warte(10);
  is(calls(), 2, "7: nach Waechterzeit freigegeben");
}

# 6. Unsinnige Aufrufe ohne Warnungen
{
  setup();
  ebusWP_Set("ebusWP", undef);
  ebusWP_Set("ebusWP", "");
  ebusWP_Set("ebusWP", "   ");
  ebusWP_Fertig(undef);
  ebusWP_Fertig("ebusWP");
  ebusWP_Set("ebusWP", "HKR1_Handsoll \x{663}\x{662}");   # arabische Ziffern 32
  is(calls(), 0, "6: kein Buszugriff bei Unsinn");
}

is(scalar(grep { /uninitialized|isn't numeric/ } @WARN), 0, "keine Perl-Warnungen (uninitialized/numeric)")
  or diag(join("", @WARN));
done_testing();
