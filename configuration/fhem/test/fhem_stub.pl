# fhem_stub.pl - minimale FHEM-Nachbildung fuer Offline-Tests von 98_EBUSFUNC.pm
#
# Benutzung in einem Test:
#   require "./fhem_stub.pl";          # aus dem Verzeichnis test/
#   stub_reset();
#   stub_device("ebusWP", { "Betriebswahl.Heizkreis.03.050" => "Automatik", ... });
#   my $err = stub_define("HK1", "ebusWP");           # define HK1 EBUSFUNC ebusWP
#   stub_attr("HK1", "readingMap", "Quelle Ziel %.1f\n...");
#   stub_event("ebusWP", "Quelle: 27.65", "Andere: 1");  # Event-Paket ans Modul
#   EBUSFUNC_Set($defs{"HK1"}, "HK1", "Handsoll", "25.5");
#   @FHEM_CMDS                         # alle fhem()-Aufrufe in Reihenfolge
#   stub_fire_timers(<epoch>)          # faellige InternalTimer ausfuehren
#   $STUB_NOW                          # aktuelle Zeit (Sekunden), veraenderbar
package main;
use strict;
use warnings;

use vars qw(%defs %attr $init_done $readingFnAttributes @FHEM_CMDS @STUB_LOG @STUB_TIMERS $STUB_NOW %modules $STUB_FHEM_RET);
$readingFnAttributes = "event-on-change-reading userReadings stateFormat";
$init_done = 1;
$STUB_NOW  = 1794700000;   # 2026-11-15 ca. 07:00 Ortszeit

sub stub_reset {
  %defs = (); %attr = (); @FHEM_CMDS = (); @STUB_LOG = (); @STUB_TIMERS = ();
  $init_done = 1; $STUB_NOW = 1794700000;
}

sub gettimeofday { return $STUB_NOW; }
sub TimeNow      { return FmtDateTime($STUB_NOW); }
sub FmtDateTime {
  my @t = localtime($_[0]);
  return sprintf("%04d-%02d-%02d %02d:%02d:%02d", $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}
sub time_str2num {
  my ($s) = @_;
  require POSIX;
  my ($Y,$M,$D,$h,$m,$sec) = $s =~ /^(\d+)-(\d+)-(\d+) (\d+):(\d+):(\d+)$/;
  return POSIX::mktime($sec, $m, $h, $D, $M-1, $Y-1900, 0, 0, -1);
}
sub Log3       { my ($n, $l, $t) = @_; push @STUB_LOG, "$l: $t"; return undef; }
sub IsDisabled { my ($n) = @_; return ($attr{$n} && $attr{$n}{disable}) ? 1 : 0; }
sub AttrVal    { my ($n, $a, $d) = @_; return ($attr{$n} && defined $attr{$n}{$a}) ? $attr{$n}{$a} : $d; }

sub ReadingsVal {
  my ($n, $r, $d) = @_;
  return $d if(!$defs{$n} || !$defs{$n}{READINGS}{$r});
  return $defs{$n}{READINGS}{$r}{VAL};
}

sub readingsBeginUpdate { my ($h) = @_; $h->{CHANGED} = []; return undef; }
sub readingsBulkUpdate {
  my ($h, $r, $v) = @_;
  $h->{READINGS}{$r} = { VAL => $v, TIME => TimeNow() };
  push @{$h->{CHANGED}}, "$r: $v";
  $h->{STUB_UPDATES}{$r}++;
  return $v;
}
sub readingsEndUpdate   { my ($h, $t) = @_; return undef; }
sub readingsSingleUpdate {
  my ($h, $r, $v, $t) = @_;
  readingsBeginUpdate($h); readingsBulkUpdate($h, $r, $v); readingsEndUpdate($h, $t);
  return undef;
}
sub readingsDelete { my ($h, $r) = @_; delete $h->{READINGS}{$r}; return undef; }

sub deviceEvents { my ($h, $s) = @_; return $h->{CHANGED}; }

# fhem(): nur protokollieren; liefert Fehlertext, wenn $STUB_FHEM_RET gesetzt
sub fhem { my ($cmd, $silent) = @_; push @FHEM_CMDS, $cmd; return $STUB_FHEM_RET; }
# CommandSet(client, "<dev> <args>"): wie im echten FHEM genau ein set; protokolliert als "set <dev> <args>"
sub CommandSet { my ($cl, $arg) = @_; push @FHEM_CMDS, "set $arg"; return $STUB_FHEM_RET; }

sub InternalTimer       { my ($t, $fn, $arg, $w) = @_; push @STUB_TIMERS, [$t, $fn, $arg]; return undef; }
sub RemoveInternalTimer { my ($arg) = @_; @STUB_TIMERS = grep { $_->[2] ne $arg } @STUB_TIMERS; return undef; }
sub stub_fire_timers {
  my ($bis) = @_;
  my @f = sort { $a->[0] <=> $b->[0] } grep { $_->[0] <= $bis } @STUB_TIMERS;
  @STUB_TIMERS = grep { $_->[0] > $bis } @STUB_TIMERS;
  foreach my $t (@f) { $STUB_NOW = $t->[0]; no strict 'refs'; &{$t->[1]}($t->[2]); }
}

# --- Hilfen fuer Tests --------------------------------------------------------
sub stub_device {
  my ($n, $readings) = @_;
  $defs{$n} = { NAME => $n, TYPE => "MQTT2_DEVICE", READINGS => {} };
  $defs{$n}{READINGS}{$_} = { VAL => $readings->{$_}, TIME => TimeNow() } foreach keys %{$readings || {}};
  return $defs{$n};
}
sub stub_set_reading { my ($n, $r, $v) = @_; $defs{$n}{READINGS}{$r} = { VAL => $v, TIME => TimeNow() }; }

sub stub_define {
  my ($n, $ebus) = @_;
  my %m; EBUSFUNC_Initialize(\%m);
  $defs{$n} = { NAME => $n, TYPE => "EBUSFUNC", READINGS => {} };
  return EBUSFUNC_Define($defs{$n}, "$n EBUSFUNC $ebus");
}
sub stub_attr {
  my ($n, $a, $v) = @_;
  my $err = EBUSFUNC_Attr("set", $n, $a, $v);
  $attr{$n}{$a} = $v if(!$err);
  return $err;
}
# Event-Paket vom Quell-Device: Readings setzen, dann NotifyFn aufrufen
sub stub_event {
  my ($src, @events) = @_;
  foreach my $e (@events) {
    my ($r, $v) = $e =~ /^([^:]+): (.*)$/;
    stub_set_reading($src, $r, $v) if(defined $r);
  }
  $defs{$src}{CHANGED} = [@events];
  foreach my $n (grep { $defs{$_}{TYPE} eq "EBUSFUNC" } keys %defs) {
    EBUSFUNC_Notify($defs{$n}, $defs{$src});
  }
}
sub R { my ($n, $r) = @_; return ReadingsVal($n, $r, undef); }

1;
