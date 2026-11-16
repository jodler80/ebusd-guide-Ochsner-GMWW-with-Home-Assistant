#!/bin/sh
# code_unveraendert.sh <alt.pm> <neu.pm>
# Prueft, ob sich zwei Fassungen eines FHEM-Moduls nur in Kommentaren/POD unterscheiden:
# beide werden per B::Deparse in Quelltext ohne Kommentare zurueckuebersetzt und verglichen.
# Exit 0 = Code identisch, 1 = Code unterschiedlich (diff wird ausgegeben), 2 = Fehler.
# Aufruf aus beliebigem Verzeichnis; nutzt fhem_proto.pm und Blocking.pm aus diesem Ordner.
T=$(dirname "$(readlink -f "$0")")
dep() { perl -I "$T" -I /opt/fhem/FHEM -Mfhem_proto -MO=Deparse,-q "$1" 2>/dev/null || { echo "Deparse fehlgeschlagen: $1" >&2; exit 2; }; }
A=$(mktemp); B=$(mktemp); trap 'rm -f "$A" "$B"' EXIT
dep "$1" > "$A"; dep "$2" > "$B"
if cmp -s "$A" "$B"; then echo "Code identisch (nur Kommentare/POD geaendert)"; exit 0; fi
echo "Code UNTERSCHIEDLICH:"; diff "$A" "$B"; exit 1
