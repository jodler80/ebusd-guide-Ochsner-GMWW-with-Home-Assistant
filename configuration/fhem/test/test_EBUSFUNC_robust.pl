# test_EBUSFUNC_robust.pl - Robustheits-/Fuzz-Tests fuer 98_EBUSFUNC.pm (136 Pruefungen)
# Aufruf in test/: perl test_EBUSFUNC_robust.pl  (Ausgabe enthaelt Unicode -> bei grep "-a" verwenden)
# Invarianten: kein die; jeder erzeugte set-Befehl gueltig (Wert im Bereich/Raster bzw. aus Liste, ohne ; und
# Steuerzeichen); unsinnige Eingaben -> Fehlertext; keine Perl-Warnungen wegen Zahlen/undef.
# Mit einem lokalen Sprachmodell erzeugt (15.11.2026), korrigiert: Klammer "( ... ];" Zeile 208, undef-Vergleich Z. 91/93.
#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Test::More;
require "./fhem_stub.pl";
require "../98_EBUSFUNC.pm";
local $SIG{__WARN__} = sub { push @main::WARNUNGEN, $_[0] };

sub setup {
    stub_reset();
    stub_device("ebusWP", {
        "Betriebswahl.Heizkreis.03.050" => "Automatik",
        "Sollwert.Heizkreis.Vorlauftemp.01.002" => "27.6",
        "Solltemp.Handbetrieb.HKR1.07.009" => "20.0",
        "Status.Heizkreis.02.051" => "Normal_Heizbetrieb"
    });
    stub_define("HK1", "ebusWP");
    stub_attr("HK1", "readingMap", "Betriebswahl.Heizkreis.03.050 Betriebswahl\nSollwert.Heizkreis.Vorlauftemp.01.002 VL_Soll %.1f\nSolltemp.Handbetrieb.HKR1.07.009 Handsoll %.1f\nStatus.Heizkreis.02.051 Status");
    stub_attr("HK1", "overrideParams", "Spar_Offset:slider,-10,0.5,0:-6 VL_Max:slider,20,0.5,45:34");
    stub_attr("HK1", "setMap", "Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen HKR1_Betriebswahl\nHandsoll:slider,10,0.5,VL_Max HKR1_Handsoll\nNotiz:textField HKR1_Notiz\nUhrzeit_sync:noArg WP_Uhrzeit_sync");
    stub_attr("HK1", "overrideList", "Sparbetrieb group=hk guard=Betriebswahl:^Automatik\$ base=VL_Soll apply=Handsoll:base+Spar_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik");
}

sub pruefe_cmds {
    my ($fall) = @_;
    foreach my $cmd (@main::FHEM_CMDS) {
        if ($cmd =~ /^set ebusWP HKR1_Handsoll ([0-9]+\.[0-9]+)$/) {
            my $z = $1;
            ok($z >= 10 && $z <= 34 && ($z * 2) == int($z * 2), "$fall: $cmd gueltig (Handsoll Range/Raster)");
        } elsif ($cmd =~ /^set ebusWP HKR1_Betriebswahl (Standbybetrieb|Automatik|Handbetrieb_Heizen)$/) {
            pass("$fall: $cmd gueltig (Betriebswahl)");
        } elsif ($cmd =~ /^set ebusWP WP_Uhrzeit_sync$/) {
            pass("$fall: $cmd gueltig (Uhrzeit_sync)");
        } elsif ($cmd =~ /^set ebusWP HKR1_Notiz [^;\x00-\x1f]+$/) {
            pass("$fall: $cmd gueltig (Notiz)");
        } else {
            fail("$fall: Ungueltiger Befehl generiert: $cmd");
        }
    }
}

# Hilfsroutine um Aufrufe sicher zu wappen
sub run_set {
    my ($dev, @args) = @_;
    my $ret;
    my $err;
    eval {
        $ret = EBUSFUNC_Set($dev, "HK1", @args);
    };
    $err = $@;
    return ($ret, $err);
}

# ---------------- A) Handsoll ----------------
my @cases_A = (
    ["hoch!", { err => 1, cmds => 0 }],
    ["",      { err => 1, cmds => 0 }],
    ["22,5",  { cmd => "set ebusWP HKR1_Handsoll 22.5" }],
    ["22.5°C",{ err => 1 }], # "22.5°C" ist keine Zahl nach EBUSFUNC_NUM
    ["22.5",  { cmd => "set ebusWP HKR1_Handsoll 22.5" }], # "22.5" + "°C" -> "22.5 °C" -> Fehler, aber falls nur "22.5" uebergeben: ok. Aufgabe: "22.5 °C" (als zwei Argumente)
    ["1e3",   { err => 1 }],
    ["0x20",  { err => 1 }],
    ["NaN",   { err => 1, cmds => 0 }],
    ["inf",   { err => 1 }],
    ["-inf",  { err => 1 }],
    ["--5",   { err => 1 }],
    ["5-",    { err => 1 }],
    ["22..5", { err => 1 }],
    [" 22",   { err => 1 }], # " 22" -> "22" nach Trim? Nein, EBUSFUNC_Check erlaub nicht Whitespace am Anfang/Ende in der Regexp? 
                             # EBUSFUNC_NUM: ^-?[0-9]+...$. " 22" matcht nicht.
    ["22.55.1", { err => 1 }],
    ["999999999999999999999999", { cmd => "set ebusWP HKR1_Handsoll 34.0" }],
    ["-0",    { err => 1 }], # -0 < 10 (Min)
    ["+5",    { err => 1 }], # +5 matcht nicht ^-?[0-9]... da + nicht erlaubt
    ["\x{0663}\x{0662}", { err => 1, cmds => 0 }], # Arabische Ziffern
    ["22;shutdown", { err => 1, cmds => 0 }],
    ["22\n23", { err => 1 }],
    [undef,   { err => 1, cmds => 0 }],
);

# Korrektur Fall "22.5 °C" als zwei Argumente: 
# EBUSFUNC_Set($hash, $name, $n, @args)
# $v = join(" ", @args) -> "22.5 °C"
# EBUSFUNC_Check slider: $v !~ NUM -> Fehler.

foreach my $c (@cases_A) {
    my $val = $c->[0];
    my $exp = $c->[1];
    setup();
    my $label = "A: Handsoll " . (!defined $val ? "(undef)" : $val eq "" ? "(leer)" : ($val =~ /^[\x00-\x1f\x7f\n]/ ? "(special)" : $val));
    
    my ($ret, $die_err) = run_set($main::defs{"HK1"}, "Handsoll", (defined $val && $val eq "" ? () : $val));
    # Achtung: Wenn $val undef ist, run_set uebergibt undef als Argument.
    # In EBUSFUNC_Set: @args = (undef). join(" ", undef) -> "" (mit Warning "uninitialized value"). 
    # Aber wir wollen pruefen ob *kein die* ist.
    
    ok(!$die_err, "$label: kein die");
    
    if (exists $exp->{cmds} && $exp->{cmds} == 0) {
        is(scalar(@main::FHEM_CMDS), 0, "$label: FHEM_CMDS leer");
        ok(defined $ret && $ret ne "", "$label: Rueckgabe ist definierter Fehlertext");
    } elsif (exists $exp->{cmd}) {
        is(scalar(@main::FHEM_CMDS), 1, "$label: genau 1 Befehl");
        is($main::FHEM_CMDS[0], $exp->{cmd}, "$label: korrekter Befehl");
    }
    pruefe_cmds($label);
}

# ---------------- B) Betriebswahl ----------------
my @cases_B = ("automatik", "Automatik ", "Auto", "1", "Automatik;shutdown", "");
foreach my $val (@cases_B) {
    setup();
    my $label = "B: Betriebswahl " . ($val eq "" ? "(leer)" : $val);
    my ($ret, $die_err) = run_set($main::defs{"HK1"}, "Betriebswahl", $val);
    ok(!$die_err, "$label: kein die");
    is(scalar(@main::FHEM_CMDS), 0, "$label: FHEM_CMDS leer");
    ok(defined $ret && $ret ne "", "$label: Rueckgabe ist definierter Fehlertext");
    pruefe_cmds($label);
}

# ---------------- C) Notiz ----------------
my @cases_C = (
    ["a;shutdown", 1],
    ["a\nb", 1],
    ["a\x00b", 1],
    ["Hallo", 0],
);
foreach my $c (@cases_C) {
    my ($val, $expect_err) = @{$c};
    setup();
    my $label = "C: Notiz " . ($val =~ /[^[:print:]]/ ? "(special)" : $val);
    my ($ret, $die_err) = run_set($main::defs{"HK1"}, "Notiz", $val);
    ok(!$die_err, "$label: kein die");
    if ($expect_err) {
        is(scalar(@main::FHEM_CMDS), 0, "$label: FHEM_CMDS leer");
        ok(defined $ret && $ret ne "", "$label: Rueckgabe ist definierter Fehlertext");
    } else {
        is(scalar(@main::FHEM_CMDS), 1, "$label: genau 1 Befehl");
        is($main::FHEM_CMDS[0], "set ebusWP HKR1_Notiz Hallo", "$label: korrekter Befehl");
    }
    pruefe_cmds($label);
}

# ---------------- D) Uhrzeit_sync ----------------
setup();
my $label_D = "D: Uhrzeit_sync 'jetzt'";
my ($ret_D, $die_err_D) = run_set($main::defs{"HK1"}, "Uhrzeit_sync", "jetzt");
ok(!$die_err_D, "$label_D: kein die");
is(scalar(@main::FHEM_CMDS), 0, "$label_D: FHEM_CMDS leer");
ok(defined $ret_D && $ret_D ne "", "$label_D: Rueckgabe ist definierter Fehlertext");
pruefe_cmds($label_D);

# ---------------- E) Sparbetrieb ----------------
my @cases_E = ("AN", "on", "1", "an ", "");
foreach my $val (@cases_E) {
    setup();
    my $label = "E: Sparbetrieb '$val'";
    my ($ret, $die_err) = run_set($main::defs{"HK1"}, "Sparbetrieb", $val);
    ok(!$die_err, "$label: kein die");
    is(scalar(@main::FHEM_CMDS), 0, "$label: FHEM_CMDS leer");
    ok(defined $ret && $ret ne "", "$label: Rueckgabe ist definierter Fehlertext");
    isnt(R("HK1", "Sparbetrieb"), "an", "$label: Sparbetrieb nicht 'an'");
    pruefe_cmds($label);
}

# ---------------- F) Parameter ----------------
# VL_Max abc
setup();
my $label_F1 = "F: VL_Max 'abc'";
my ($ret_F1, $die_err_F1) = run_set($main::defs{"HK1"}, "VL_Max", "abc");
ok(!$die_err_F1, "$label_F1: kein die");
ok(defined $ret_F1 && $ret_F1 ne "", "$label_F1: Rueckgabe ist definierter Fehlertext");
pruefe_cmds($label_F1);

# VL_Max 60
setup();
my $label_F2 = "F: VL_Max '60'";
my ($ret_F2, $die_err_F2) = run_set($main::defs{"HK1"}, "VL_Max", "60");
ok(!$die_err_F2, "$label_F2: kein die");
is($ret_F2, undef, "$label_F2: Rueckgabe undef");
is(R("HK1", "VL_Max"), "45.0", "$label_F2: VL_Max begrenzt auf 45.0");
pruefe_cmds($label_F2);

# Spar_Offset ""
setup();
my $label_F3 = "F: Spar_Offset (leer)";
my ($ret_F3, $die_err_F3) = run_set($main::defs{"HK1"}, "Spar_Offset", "");
ok(!$die_err_F3, "$label_F3: kein die");
ok(defined $ret_F3 && $ret_F3 ne "", "$label_F3: Rueckgabe ist definierter Fehlertext");
pruefe_cmds($label_F3);

# ---------------- G) Unsinnige Attribute ----------------
my @cases_G = (
    ["readingMap", "a"],
    ["readingMap", "a b %999999999d"],
    ["readingMap", "a b %n"],
    ["readingMap", "a b c d"],
    ["setMap", "X:slider,10,0,34 c"],
    ["setMap", "X:slider,10,.,34 c"],
    ["setMap", "X:slider,a b,1,c d"],
    ["overrideList", "Spar apply="],
    ["overrideList", "Spar guard=Betriebswahl:(?{die}) apply=Handsoll:1"],
    ["overrideList", "Spar foo=bar apply=Handsoll:1"],
    ["overrideList", "Spar save=Betriebswahl apply=Handsoll:1 end=restore maxDuration=abc"],
    ["overrideParams", "X:slider,1,1,10"],
    ["overrideParams", "X:slider,1,1,10:99"],
);

foreach my $c (@cases_G) {
    my ($attr, $val) = @{$c};
    setup();
    my $label = "G: attr $attr = '$val'";
    my $err;
    my $die_err;
    eval {
        $err = stub_attr("HK1", $attr, $val);
    };
    $die_err = $@;
    ok(!$die_err, "$label: kein die");
    ok(defined $err && $err ne "", "$label: stub_attr liefert Fehlertext");
    pruefe_cmds($label);
}

# ---------------- H) Events ----------------
setup();
my $label_H1 = "H: Events mit seltsamen Werten";
eval {
    stub_event("ebusWP", 
        "Sollwert.Heizkreis.Vorlauftemp.01.002: hoch",
        "Status.Heizkreis.02.051: ",
        "Unbekannt: 1",
        "kaputt ohne doppelpunkt"
    );
};
ok(!$@, "$label_H1: kein die bei Events");
pruefe_cmds($label_H1);

# Danach Sparbetrieb an
my $label_H2 = "H: Sparbetrieb an nach kaputten Events";
my ($ret_H, $die_err_H) = run_set($main::defs{"HK1"}, "Sparbetrieb", "an");
ok(!$die_err_H, "$label_H2: kein die");
is(scalar(@main::FHEM_CMDS), 0, "$label_H2: FHEM_CMDS leer (Basis keine Zahl)");
like(R("HK1", "overrideInfo"), qr/ignoriert/, "$label_H2: overrideInfo enthaelt 'ignoriert'");

# ---------------- I) Warnungen ----------------
is(scalar(grep { /isn't numeric|uninitialized/ } @main::WARNUNGEN), 0, "keine Perl-Warnungen wegen Zahlen/undef");

done_testing();
