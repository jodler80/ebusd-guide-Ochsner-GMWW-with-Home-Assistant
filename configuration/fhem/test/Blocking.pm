# Blocking.pm (Test-Ersatz) - ersetzt FHEMs Blocking.pm in Offline-Tests/Deparse.
# BlockingCall startet keinen Kindprozess, sondern protokolliert den Aufruf in @main::STUB_BLOCKING.
# Liefert einen Pseudo-Hash wie FHEM; mit $main::STUB_BLOCKING_FAIL = 1 liefert er undef (Fork fehlgeschlagen).
package main;
use vars qw(@STUB_BLOCKING $STUB_BLOCKING_FAIL);
sub BlockingCall {
  my ($fn, $arg, $finishFn, $timeout, $abortFn, $abortArg) = @_;
  push @STUB_BLOCKING, { fn => $fn, arg => $arg, finish => $finishFn, timeout => $timeout, abort => $abortFn, abortArg => $abortArg };
  return undef if($STUB_BLOCKING_FAIL);
  return { pid => 4711, fn => $fn };
}
sub BlockingKill { return undef; }
1;
