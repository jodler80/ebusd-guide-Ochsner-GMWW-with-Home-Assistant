# test_EBUSFUNC.pl - Offline-Tests fuer 98_EBUSFUNC.pm (19 Faelle, 73 Pruefungen)
# Aufruf im Verzeichnis test/:  perl test_EBUSFUNC.pl   (oder: prove test_EBUSFUNC.pl)
# Erwartete Werte aus dem abgestimmten Entwurf vorgegeben; Skript mit einem lokalen Sprachmodell
# (15.11.2026) erzeugt, danach mechanisch korrigiert: like(..., /re/) -> qr/re/, is(defined X,0) -> ok(!defined X).
use strict;
use warnings;
use Test::More;

require "./fhem_stub.pl";
require "../98_EBUSFUNC.pm";

sub setup_hk1 {
  stub_reset();
  stub_device("ebusWP", {
    "Betriebswahl.Heizkreis.03.050" => "Automatik",
    "Sollwert.Heizkreis.Vorlauftemp.01.002" => "27.6",
    "Solltemp.Handbetrieb.HKR1.07.009" => "20.0",
    "Status.Heizkreis.02.051" => "Normal_Heizbetrieb"
  });
  stub_define("HK1", "ebusWP");
  stub_attr("HK1", "readingMap",
    "Betriebswahl.Heizkreis.03.050 Betriebswahl\n" .
    "Sollwert.Heizkreis.Vorlauftemp.01.002 VL_Soll %.1f\n" .
    "Solltemp.Handbetrieb.HKR1.07.009 Handsoll %.1f\n" .
    "Status.Heizkreis.02.051 Status"
  );
  stub_attr("HK1", "setMap",
    "Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen HKR1_Betriebswahl\n" .
    "Handsoll:slider,10,0.5,34 HKR1_Handsoll\n" .
    "Uhrzeit_sync:noArg WP_Uhrzeit_sync"
  );
  stub_attr("HK1", "overrideParams",
    "Spar_Offset:slider,-10,0.5,0:-6 EV_Offset:slider,0,0.5,10:5"
  );
  stub_attr("HK1", "overrideList",
    "Sparbetrieb group=hk guard=Betriebswahl:^Automatik\$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb)\$ base=VL_Soll apply=Handsoll:base+Spar_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik maxDuration=240\n" .
    "Eigenverbrauch_Vorrang group=hk guard=Betriebswahl:^Automatik\$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb)\$ base=VL_Soll apply=Handsoll:base+EV_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik"
  );
}

# Fall 1
setup_hk1();
is(R("HK1","VL_Soll"), "27.6", "1. VL_Soll gespiegelt");
is(R("HK1","Status"), "Normal_Heizbetrieb", "1. Status gespiegelt");
is(R("HK1","Spar_Offset"), "-6", "1. Spar_Offset Default");
is(R("HK1","EV_Offset"), "5", "1. EV_Offset Default");

# Fall 2
setup_hk1();
stub_attr("HK1", "readingMap",
  "Betriebswahl.Heizkreis.03.050 Betriebswahl\n" .
  "Sollwert.Heizkreis.Vorlauftemp.01.002 VL_Soll %.1f\n" .
  "Solltemp.Handbetrieb.HKR1.07.009 Handsoll %.1f\n" .
  "Status.Heizkreis.02.051 Status\n" .
  "GibtsNicht.01 X"
);
like(R("HK1","mapWarnings"), qr/GibtsNicht\.01/, "2. mapWarnings erkennt fehlendes Reading");

# Fall 3
setup_hk1();
stub_event("ebusWP", "Sollwert.Heizkreis.Vorlauftemp.01.002: 28.04", "Status.Heizkreis.02.051: Spar_Heizbetrieb");
is(R("HK1","VL_Soll"), "28.0", "3. VL_Soll aktualisiert und formatiert");
is(R("HK1","Status"), "Spar_Heizbetrieb", "3. Status aktualisiert");

# Fall 4
setup_hk1();
my $count_before = $main::defs{"HK1"}{STUB_UPDATES}{"VL_Soll"} // 0;
stub_event("ebusWP", "Sollwert.Heizkreis.Vorlauftemp.01.002: 27.6");
my $count_after = $main::defs{"HK1"}{STUB_UPDATES}{"VL_Soll"} // 0;
is($count_after, $count_before, "4. Unveraenderter Wert wird nicht erneut geschrieben");

# Fall 5
setup_hk1();
my $ret5 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "25.5");
is($ret5, undef, "5. set Handsoll liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 25.5"], "5. FHEM_CMDS korrekt");

# Fall 6
setup_hk1();
$ret5 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "22.44");
is($ret5, undef, "6a. set Handsoll 22.44 liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 22.5"], "6a. FHEM_CMDS gerundet");
ok(!defined R("HK1","lastWarning"), "6a. lastWarning undef");

@main::FHEM_CMDS = ();
$ret5 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "-5");
is($ret5, undef, "6b. set Handsoll -5 liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 10.0"], "6b. FHEM_CMDS begrenzt min");
like(R("HK1","lastWarning"), qr/begrenzt auf min 10/, "6b. lastWarning min");

@main::FHEM_CMDS = ();
$ret5 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "40");
is($ret5, undef, "6c. set Handsoll 40 liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 34.0"], "6c. FHEM_CMDS begrenzt max");
like(R("HK1","lastWarning"), qr/begrenzt auf max 34/, "6c. lastWarning max");

@main::FHEM_CMDS = ();
my $ret6d = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "abc");
like($ret6d, qr/keine Zahl/, "6d. set Handsoll abc liefert Fehler");

# Fall 7
setup_hk1();
my $ret7 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Betriebswahl", "Automatik");
is($ret7, undef, "7. set Betriebswahl Automatik liefert undef");
is_deeply([@main::FHEM_CMDS], [], "7. Keine FHEM_CMDS (unveraendert)");
like(R("HK1","lastCmd"), qr/^unveraendert/, "7. lastCmd zeigt unveraendert");

# Fall 8
setup_hk1();
my $ret8 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Betriebswahl", "Foo");
like($ret8, qr/nicht erlaubt/, "8. set Betriebswahl Foo liefert Fehler");

# Fall 9
setup_hk1();
@main::FHEM_CMDS = ();
my $ret9 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Uhrzeit_sync", "");
is($ret9, undef, "9. set Uhrzeit_sync liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP WP_Uhrzeit_sync"], "9. FHEM_CMDS noArg");

# Fall 10
setup_hk1();
@main::FHEM_CMDS = ();
my $ret10 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Sparbetrieb", "an");
is($ret10, undef, "10. set Sparbetrieb an liefert undef");
is_deeply([@main::FHEM_CMDS],
  ["set ebusWP HKR1_Handsoll 21.5", "set ebusWP HKR1_Betriebswahl Handbetrieb_Heizen"],
  "10. FHEM_CMDS Sparbetrieb apply");
is(R("HK1","Sparbetrieb"), "an", "10. Sparbetrieb Status an");
is(R("HK1","saved_hk_base"), "27.6", "10. saved_hk_base korrekt");
is(R("HK1","overrideActive"), "Sparbetrieb", "10. overrideActive Sparbetrieb");
ok(defined R("HK1","Sparbetrieb_Ende"), "10. Sparbetrieb_Ende definiert");

# Fall 11
# Zustand aus Fall 10 uebernehmen (da setup_hk1 neu startet, muss Fall 10 nicht explizit geladen werden,
# aber die Aufgabe sagt "nach Fall 10". Wir setzen es auf, dann Event, dann Wechsel)
# Wir brauchen den Zustand nach Fall 10. Da setup_hk1 resetet, muessen wir den Ablauf simulieren.
# Fall 10 hat Sparbetrieb aktiviert.
# Jetzt: Event kommt rein, dann Eigenverbrauch an.

# Wir starten neu und simulieren die Vorgaenge, um den Kontext zu haben?
# Nein, die Aufgabe sagt "nach Fall 10". Das impliziert, dass der Zustand von Fall 10 besteht.
# Da ich in den Tests isoliert arbeite, muess ich den Zustand von Fall 10 in Fall 11 replizieren oder
# die Tests so schreiben, dass sie vom Zustand ausgehen.
# Die Anleitung sagt: "Gemeinsamer Aufbau HK1 ... ruft stub_reset".
# Fall 11 beginnt mit "nach Fall 10". Das bedeutet, ich muss den Zustand von Fall 10 herstellen,
# bevor ich den neuen Teil teste.
# Aber die Testfaelle sind nummeriert. Normalerweise laeuft das Skript linear.
# Wenn ich in Fall 10 setup_hk1() rufe, ist der Zustand frisch.
# Dann setze ich Sparbetrieb an.
# In Fall 11 muss ich *nicht* setup_hk1() rufen, sondern aufbauen auf dem Zustand von Fall 10.
# ABER: Die Instruktion sagt "Am Anfang jedes Falls aufrufen" fuer setup_hk1?
# "Gemeinsamer Aufbau HK1 (in einer Hilfsfunktion setup_hk1(), am Anfang jedes Falls aufrufen, ruft stub_reset)"
# Das steht unter "Gemeinsamer Aufbau". Es scheint, dass jeder Testfall mit einem frischen Start beginnt,
# AUSSER wo explizit anders angegeben (wie "nach Fall 10").
# Wenn ich setup_hk1 in Fall 11 rufe, ist Sparbetrieb "aus".
# Die Instruktion fuer Fall 11: "Wechsel: nach Fall 10 stub_event(...), FHEM_CMDS leeren, Eigenverbrauch_Vorrang an -> ..."
# Das bedeutet, ich muss den Zustand von Fall 10 wiederherstellen, ODER der Test Fall 10 wurde gerade ausgefuehrt.
# Da das ein einzelnes Skript ist, laufen die Tests nacheinander.
# Wenn ich in Fall 10 setup_hk1() rufe, und dann die Aktion, ist der Zustand da.
# In Fall 11 sollte ich NICHT setup_hk1() rufen, sondern den Zustand von 10 verwenden.
# ABER: Die Anweisung "am Anfang jedes Falls aufrufen" ist fuer den "Gemeinsamen Aufbau".
# Ich interpretiere das so: Faelle die "setup_hk1" erwaehlen oder als frisch beginnen, rufen es auf.
# Fall 11 verweist auf Fall 10. Ich werde in Fall 11 den Zustand von Fall 10 simulieren, indem ich
# die Aktionen von Fall 10 ausfuehre, ODER ich nehme an, dass die Tests linear laufen und ich
# in Fall 11 NICHT resete.
# Aber die anderen Faelle (1-9, 13-19) haben explizit "setup_hk1" in der Beschreibung oder beginnen frisch.
# Fall 11 und 12 sind ein Zug.
# Ich werde in Fall 10 setup_hk1 rufen.
# In Fall 11 rufe ich NICHT setup_hk1, sondern setze das Event und die neuen Befehle.
# In Fall 12 rufe ich NICHT setup_hk1, sondern setze die neuen Befehle.

# Falls das Skript als Ganzes durchlauft, ist der Zustand nach Fall 10 da.
# Ich werde Fall 10 wie oben geschrieben lassen.
# Fuer Fall 11:
stub_event("ebusWP", "Betriebswahl.Heizkreis.03.050: Handbetrieb_Heizen", "Solltemp.Handbetrieb.HKR1.07.009: 21.5");
@main::FHEM_CMDS = ();
my $ret11 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Eigenverbrauch_Vorrang", "an");
is($ret11, undef, "11. set Eigenverbrauch_Vorrang an liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 32.5"], "11. FHEM_CMDS Eigenverbrauch apply");
is(R("HK1","Sparbetrieb"), "aus", "11. Sparbetrieb ist aus");
is(R("HK1","Eigenverbrauch_Vorrang"), "an", "11. Eigenverbrauch_Vorrang ist an");
is(R("HK1","saved_hk_base"), "27.6", "11. saved_hk_base bleibt 27.6");

# Fall 12
@main::FHEM_CMDS = ();
my $ret12 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Eigenverbrauch_Vorrang", "aus");
is($ret12, undef, "12. set Eigenverbrauch_Vorrang aus liefert undef");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Betriebswahl Automatik"], "12. FHEM_CMDS end");
ok(!defined R("HK1","saved_hk_base"), "12. saved_hk_base undef");
is(R("HK1","overrideActive"), "-", "12. overrideActive -");

# Fall 13
setup_hk1();
stub_event("ebusWP", "Betriebswahl.Heizkreis.03.050: Standbybetrieb");
@main::FHEM_CMDS = ();
my $ret13 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Sparbetrieb", "an");
is($ret13, undef, "13. set Sparbetrieb an liefert undef (Guard)");
is_deeply([@main::FHEM_CMDS], [], "13. Keine FHEM_CMDS (Guard ignoriert)");
isnt(R("HK1","Sparbetrieb"), "an", "13. Sparbetrieb ist nicht an");
like(R("HK1","overrideInfo"), qr/^ignoriert/, "13. overrideInfo ignoriert");

# Fall 14
# Begrenzung oben
setup_hk1();
stub_event("ebusWP", "Sollwert.Heizkreis.Vorlauftemp.01.002: 33.0");
@main::FHEM_CMDS = ();
my $ret14a = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Eigenverbrauch_Vorrang", "an");
is($ret14a, undef, "14a. set Eigenverbrauch_Vorrang an liefert undef");
is($main::FHEM_CMDS[0], "set ebusWP HKR1_Handsoll 34.0", "14a. FHEM_CMDS begrenzt max");

# Begrenzung unten
setup_hk1();
stub_event("ebusWP", "Sollwert.Heizkreis.Vorlauftemp.01.002: 12.0");
@main::FHEM_CMDS = ();
my $ret14b = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Sparbetrieb", "an");
is($ret14b, undef, "14b. set Sparbetrieb an liefert undef");
is($main::FHEM_CMDS[0], "set ebusWP HKR1_Handsoll 10.0", "14b. FHEM_CMDS begrenzt min");

# Fall 15
setup_hk1();
@main::FHEM_CMDS = ();
my $ret15_1 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Sparbetrieb", "an");
is($ret15_1, undef, "15. set Sparbetrieb an liefert undef");
stub_event("ebusWP", "Betriebswahl.Heizkreis.03.050: Handbetrieb_Heizen");
@main::FHEM_CMDS = ();
stub_fire_timers($main::STUB_NOW + 240 * 60);
is(R("HK1","Sparbetrieb"), "aus", "15. Sparbetrieb ist aus");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Betriebswahl Automatik"], "15. FHEM_CMDS end nach Timeout");
like(R("HK1","overrideInfo"), qr/Hoechstdauer/, "15. overrideInfo Hoechstdauer");

# Fall 16
setup_hk1();
@main::FHEM_CMDS = ();
my $ret16a = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Spar_Offset", "-5");
is($ret16a, undef, "16a. set Spar_Offset -5 liefert undef");
is(R("HK1","Spar_Offset"), "-5.0", "16a. Spar_Offset Wert -5.0");

@main::FHEM_CMDS = ();
my $ret16b = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Spar_Offset", "-11");
is($ret16b, undef, "16b. set Spar_Offset -11 liefert undef");
is(R("HK1","Spar_Offset"), "-10.0", "16b. Spar_Offset begrenzt -10.0");
like(R("HK1","lastWarning"), qr/begrenzt/, "16b. lastWarning begrenzt");

# Fall 17
setup_hk1();
$main::attr{"HK1"}{disable} = 1;
@main::FHEM_CMDS = ();
my $ret17 = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "25.5");
like($ret17, qr/deaktiviert/, "17. set Handsoll liefert deaktiviert");
is_deeply([@main::FHEM_CMDS], [], "17. Keine FHEM_CMDS");

# Fall 18
stub_reset();
stub_device("ebusWP", {
  "Betriebswahl.Warmwasser.05.050" => "Automatik",
  "Warmwassertemp.SOLL.05.051" => "43.0"
});
stub_define("WW", "ebusWP");
stub_attr("WW", "readingMap", "Betriebswahl.Warmwasser.05.050 Betriebswahl\nWarmwassertemp.SOLL.05.051 Sollwert %.1f");
stub_attr("WW", "setMap", "Betriebswahl:Keine_Ladung,Automatik,Normaltemperatur WW_Betriebswahl\nSollwert:slider,10,1,60 WW_Sollwert");
stub_attr("WW", "overrideList", "Eigenverbrauch_Vorrang save=Betriebswahl,Sollwert apply=Betriebswahl:Normaltemperatur,Sollwert:60 end=restore");

@main::FHEM_CMDS = ();
my $ret18a = EBUSFUNC_Set($main::defs{"WW"}, "WW", "Eigenverbrauch_Vorrang", "an");
is($ret18a, undef, "18a. set WW Eigenverbrauch an liefert undef");
is_deeply([@main::FHEM_CMDS],
  ["set ebusWP WW_Betriebswahl Normaltemperatur", "set ebusWP WW_Sollwert 60"],
  "18a. FHEM_CMDS WW apply");
is(R("WW","saved_Eigenverbrauch_Vorrang_Betriebswahl"), "Automatik", "18a. saved Betriebswahl");
is(R("WW","saved_Eigenverbrauch_Vorrang_Sollwert"), "43.0", "18a. saved Sollwert");

stub_event("ebusWP", "Betriebswahl.Warmwasser.05.050: Normaltemperatur", "Warmwassertemp.SOLL.05.051: 60.0");
@main::FHEM_CMDS = ();
my $ret18b = EBUSFUNC_Set($main::defs{"WW"}, "WW", "Eigenverbrauch_Vorrang", "aus");
is($ret18b, undef, "18b. set WW Eigenverbrauch aus liefert undef");
is_deeply([@main::FHEM_CMDS],
  ["set ebusWP WW_Betriebswahl Automatik", "set ebusWP WW_Sollwert 43"],
  "18b. FHEM_CMDS WW restore");
ok(!defined R("WW","saved_Eigenverbrauch_Vorrang_Sollwert"), "18b. saved Sollwert undef");

# Fall 19
setup_hk1();
stub_attr("HK1", "overrideParams", "Spar_Offset:slider,-10,0.5,0:-6 EV_Offset:slider,0,0.5,10:5 VL_Max:slider,20,0.5,45:30");
stub_attr("HK1", "setMap",
  "Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen HKR1_Betriebswahl\n" .
  "Handsoll:slider,10,0.5,VL_Max HKR1_Handsoll\n" .
  "Uhrzeit_sync:noArg WP_Uhrzeit_sync"
);

@main::FHEM_CMDS = ();
my $ret19a = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "32");
is($ret19a, undef, "19a. set Handsoll 32 liefert undef (begrenzt auf 30)");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 30.0"], "19a. FHEM_CMDS begrenzt auf 30.0");

@main::FHEM_CMDS = ();
my $ret19b = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "VL_Max", "33");
is($ret19b, undef, "19b. set VL_Max 33 liefert undef");

@main::FHEM_CMDS = ();
my $ret19c = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "Handsoll", "32");
is($ret19c, undef, "19c. set Handsoll 32 liefert undef (nun erlaubt bis 33, aber 32 ist im Raster? 10+44*0.5=32, ja)");
is_deeply([@main::FHEM_CMDS], ["set ebusWP HKR1_Handsoll 32.0"], "19c. FHEM_CMDS 32.0");

my $ret19d = EBUSFUNC_Set($main::defs{"HK1"}, "HK1", "?");
like($ret19d, qr/Handsoll:slider,10,0\.5,33/, "19d. ? zeigt aktualisierte Maximalgrenze 33");

done_testing();
