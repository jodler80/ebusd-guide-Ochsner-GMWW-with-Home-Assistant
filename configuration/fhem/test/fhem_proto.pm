# fhem_proto.pm - macht FHEM-Funktionen/-Variablen bekannt, damit Module ausserhalb von FHEM
# kompilieren (z. B. fuer den Kommentar-Vergleich per B::Deparse). Keine Implementierungen.
# Aufruf: perl -I test -I /opt/fhem/FHEM -Mfhem_proto -MO=Deparse,-q <modul.pm>
package main;
use vars qw(%defs %attr %modules $init_done $readingFnAttributes);
sub Log3($$$);  sub Log($$);
1;
