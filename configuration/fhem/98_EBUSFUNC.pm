##############################################################################
#
#  98_EBUSFUNC.pm
#  $Id$
#
#  License: GPL v2 or later (like FHEM).
#  This program is free software; you can redistribute it and/or modify it under
#  the terms of the GNU General Public License as published by the Free Software
#  Foundation; either version 2 of the License, or (at your option) any later
#  version. It is distributed WITHOUT ANY WARRANTY; see <https://www.gnu.org/licenses/>.
#  Writing to a heat pump is at your own risk.
#
#  DE: Funktionsblock ueber einem ebusd-Device fuer FHEM.
#      Buendelt die Werte eines vorhandenen ebusd-Devices (z. B. MQTT2_DEVICE
#      mit ebusd-Readings) zu einem Funktionsblock wie Heizkreis, Warmwasser
#      oder Waermepumpe:
#        readingMap     - Werte spiegeln (optional formatiert)
#        setMap         - Bedienbefehle pruefen und an das ebusd-Device geben
#        overrideList   - Sonderfunktionen: merken, ueberschreiben, zurueckstellen
#                         (z. B. Spar-/Eigenverbrauchsbetrieb fuer einen
#                         Energiemanager)
#        overrideParams - einstellbare Parameter (Offsets, Grenzwerte)
#      Alles Anlagen-Spezifische steht in Attributen; der Code kennt keine
#      Hersteller- oder Parameternamen. Bedienung: commandref (DE/EN) am Ende
#      dieser Datei.
#      Robustheit: Unsinnige Eingaben (Text statt Zahl, Einheiten, Steuer-
#      zeichen, kaputte Attribute) fuehren zu Fehlermeldungen, nie zu einem
#      Absturz von FHEM oder einem ungeprueften Schreibbefehl.
#
#  EN: Function block on top of an ebusd device for FHEM.
#      Bundles the values of an existing ebusd device (e.g. an MQTT2_DEVICE
#      with ebusd readings) into a function block such as heating circuit,
#      hot water or heat pump:
#        readingMap     - mirror values (optionally formatted)
#        setMap         - validate commands and pass them to the ebusd device
#        overrideList   - overrides: save, override, restore
#                         (e.g. economy / self-consumption mode for an
#                         energy manager)
#        overrideParams - adjustable parameters (offsets, limits)
#      Everything installation-specific lives in attributes; the code knows no
#      manufacturer or parameter names. Usage: commandref (DE/EN) at the end of
#      this file.
#      Robustness: nonsensical input (text instead of numbers, units, control
#      characters, broken attributes) results in error messages, never in a
#      crash of FHEM or an unvalidated write command.
#
#  Version 2026-11-16
#
##############################################################################
package main;
use strict;
use warnings;

# Restrict numeric validation to ASCII digits only.
# Perl's \d matches Unicode digits which may be interpreted as 0 in calculations, causing logic errors.
my $EBUSFUNC_NUM = qr/^-?[0-9]+(?:\.[0-9]+)?$/;
# Whitelist for printf formats in readingMap.
# Prevents dangerous formats like %n or width specifiers that could cause memory issues or security risks.
my $EBUSFUNC_FMT = qr/^%[-+ 0]?[0-9]?(?:\.[0-9])?[dfs]$/;

# Initializes the EBUSFUNC device type by registering its lifecycle callbacks and attribute definitions.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_Initialize($) {
  my ($hash) = @_;
  # Register core lifecycle functions for define, undef, set, attr, and notification handling.
  $hash->{DefFn}    = "EBUSFUNC_Define";
  $hash->{UndefFn}  = "EBUSFUNC_Undef";
  $hash->{SetFn}    = "EBUSFUNC_Set";
  $hash->{AttrFn}   = "EBUSFUNC_Attr";
  $hash->{NotifyFn} = "EBUSFUNC_Notify";
  # Define available attributes. readingMap/setMap/overrideList/overrideParams accept long text fields for configuration.
  $hash->{AttrList} = "disable:0,1 readingMap:textField-long setMap:textField-long "
                    . "overrideList:textField-long overrideParams:textField-long "
                    . $readingFnAttributes;
}

# --- Define / Undef ----------------------------------------------------------
# Defines a new EBUSFUNC device linked to an existing ebus device (e.g., MQTT2).
# All vendor-specific logic is abstracted into attributes; this code is vendor-agnostic.
# Parameters:
#   $hash - Device hash reference
#   $def  - Definition string (e.g., "name EBUSFUNC ebusDevice")
# Returns:
#   Error message on failure, undef on success
sub EBUSFUNC_Define($$) {
  my ($hash, $def) = @_;
  # Validate command syntax: exactly 3 parts (name, type, target device).
  my @a = split(/\s+/, $def);
  return "Usage: define <name> EBUSFUNC <ebusDevice>" if(@a != 3);
  my ($name, undef, $ebus) = @a;
  # Store the parent ebus device and set up notification subscriptions (global + specific device).
  $hash->{EBUSDEV}   = $ebus;
  $hash->{NOTIFYDEV} = "global,$ebus";
  $hash->{STATE}     = "defined" if(!defined $hash->{STATE});
  # Initialize internal helper structures for maps, set definitions, overrides, and parameters.
  $hash->{helper}{map} //= {};
  $hash->{helper}{set} //= {};
  $hash->{helper}{ovr} //= {};
  $hash->{helper}{par} //= {};
  # If FHEM is already initialized, start the module immediately (apply defaults, sync values, restore timers).
  EBUSFUNC_Start($hash) if($init_done);
  return undef;
}

# Cleans up the EBUSFUNC device, removing all associated internal timers.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_Undef($$) {
  my ($hash) = @_;
  # Remove the main internal timer if present.
  RemoveInternalTimer($hash);
  # Remove any specific override timers stored in the helper hash.
  foreach my $o (keys %{$hash->{helper}{timer} // {}}) {
    RemoveInternalTimer($hash->{helper}{timer}{$o});
  }
  return undef;
}

# Performs initialization or re-initialization steps: sets parameter defaults, syncs readings, checks map warnings, and restores timers.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_Start($) {
  my ($hash) = @_;
  EBUSFUNC_ParamDefaults($hash);
  EBUSFUNC_SyncAll($hash);
  EBUSFUNC_MapWarnings($hash);
  EBUSFUNC_RestoreTimers($hash);
}

# --- Attribute ---------------------------------------------------------------
# Handles attribute changes for readingMap, setMap, overrideParams, and overrideList.
# Validates the input and updates internal helper structures. Triggers re-sync if FHEM is running.
# Parameters:
#   $cmd  - "del" or "attr"
#   $name - Device name
#   $attr - Attribute name
#   $val  - New attribute value
# Returns:
#   Error message on validation failure, undef on success
sub EBUSFUNC_Attr($$$$) {
  my ($cmd, $name, $attr, $val) = @_;
  my $hash = $defs{$name};
  return undef if(!$hash);
  $val = "" if($cmd eq "del" || !defined $val);
  my ($res, $err);
  if($attr eq "readingMap") {
    # Parse and validate the reading mapping configuration.
    ($res, $err) = EBUSFUNC_ParseMap($val);
    return "$name readingMap: $err" if($err);
    $hash->{helper}{map} = $res;
    if($init_done) { EBUSFUNC_SyncAll($hash); EBUSFUNC_MapWarnings($hash); }
  } elsif($attr eq "setMap") {
    # Parse and validate the set command mapping configuration.
    ($res, $err) = EBUSFUNC_ParseSetMap($val);
    return "$name setMap: $err" if($err);
    $hash->{helper}{set} = $res;
  } elsif($attr eq "overrideParams") {
    # Parse and validate override parameter definitions.
    ($res, $err) = EBUSFUNC_ParseParams($val);
    return "$name overrideParams: $err" if($err);
    $hash->{helper}{par} = $res;
    EBUSFUNC_ParamDefaults($hash) if($init_done);
  } elsif($attr eq "overrideList") {
    # Parse and validate special function (override) definitions.
    ($res, $err) = EBUSFUNC_ParseOverrides($val);
    return "$name overrideList: $err" if($err);
    $hash->{helper}{ovr} = $res;
  }
  return undef;
}

# Parses a multi-line text block, stripping empty lines, comments (#...), and leading/trailing whitespace.
# Parameters:
#   $txt - Input text
# Returns:
#   List of cleaned lines
sub EBUSFUNC_Lines($) {
  my ($txt) = @_;
  return grep { $_ ne "" && $_ !~ /^#/ } map { my $l = $_; $l =~ s/^\s+|\s+$//g; $l } split(/\n/, $txt // "");
}

# Parses the readingMap attribute.
# Format per line: <SourceReading> <TargetReading> [<printf-Format>]
# Prevents overwriting internal FHEM/Module readings and restricts formats to a safe whitelist.
# Parameters:
#   $txt - Attribute value
# Returns:
#   (\%mapping, undef) on success, (undef, $error) on failure
sub EBUSFUNC_ParseMap($) {
  my ($txt) = @_;
  my %m;
  foreach my $l (EBUSFUNC_Lines($txt)) {
    my ($src, $dst, $fmt, @rest) = split(/\s+/, $l);
    return (undef, "Zeile '$l': erwartet <Quelle> <Ziel> [<Format>]") if(!defined $dst || @rest);
    # Target must be a valid FHEM reading name.
    return (undef, "Ziel '$dst' ist kein gueltiger Reading-Name") if($dst !~ /^[A-Za-z0-9_.\-\/]+$/);
    # Critical: Prevent users from mapping to internal module states (lastCmd, overrideActive, etc.) which would break logic.
    return (undef, "Ziel '$dst' ist ein internes Reading des Moduls")
      if($dst =~ /^(lastCmd|lastCmdTime|lastWarning|mapWarnings|overrideActive|overrideInfo|state)$|^saved_|_Ende$/);
    # Enforce safe printf formats to avoid security risks or performance issues.
    return (undef, "Format '$fmt' nicht erlaubt (z. B. %.1f, %d, %s)") if(defined $fmt && $fmt !~ $EBUSFUNC_FMT);
    push @{$m{$src}}, [$dst, $fmt];
  }
  return (\%m, undef);
}

# Parses widget specification strings for UI elements (FHEMWEB).
# Supports: "noArg", "slider,min,step,max", "enum,a,b,c", or "free".
# Slider limits (min/max) can be numbers or parameter names (for dynamic limits).
# Parameters:
#   $w - Widget string
# Returns:
#   Hashref describing the widget, or undef on error
sub EBUSFUNC_Widget($) {
  my ($w) = @_;
  return { type => "free" } if(!defined $w || $w eq "");
  return { type => "noArg" } if($w eq "noArg");
  if($w =~ /^slider,([A-Za-z0-9_.\-]+),([0-9.]+),([A-Za-z0-9_.\-]+)/) {
    my ($min, $step, $max) = ($1, $2, $3);   # min/max can be a fixed number or a parameter name.
    # Step must be a positive number.
    return undef if($step !~ $EBUSFUNC_NUM || $step <= 0);
    # Limits must be either a number or a valid identifier (parameter name).
    foreach my $g ($min, $max) {             # Grenze: Zahl oder gueltiger Parametername
      return undef if($g !~ $EBUSFUNC_NUM && $g !~ /^[A-Za-z_][A-Za-z0-9_.\-]*$/);
    }
    # If both limits are fixed numbers, min must be <= max.
    return undef if($min =~ $EBUSFUNC_NUM && $max =~ $EBUSFUNC_NUM && $min > $max);
    # Determine decimal places for formatting based on the step size.
    my $dec = ($step =~ /\.(\d+)$/) ? length($1) : 0;
    return { type => "slider", min => $min, step => $step, max => $max, dec => $dec, widget => $w };
  }
  # Comma-separated list implies an enumeration (dropdown).
  return { type => "enum", values => [split(/,/, $w)], widget => $w } if($w =~ /,/);
  return { type => "free", widget => $w };
}

# Parses the setMap attribute.
# Format per line: <CommandName>[:<WidgetSpec>] <TargetBusCommand>
# Parameters:
#   $txt - Attribute value
# Returns:
#   (\%mapping, undef) on success, (undef, $error) on failure
sub EBUSFUNC_ParseSetMap($) {
  my ($txt) = @_;
  my %s;
  foreach my $l (EBUSFUNC_Lines($txt)) {
    my ($nw, $cmd, @rest) = split(/\s+/, $l);
    return (undef, "Zeile '$l': erwartet <Name>[:<Widget>] <Ziel-Befehl>") if(!defined $cmd || @rest);
    my ($n, $w) = split(/:/, $nw, 2);
    # Command name must be valid.
    return (undef, "Name '$n' ungueltig") if($n !~ /^[A-Za-z0-9_.\-]+$/);
    # Validate widget specification.
    my $wd = EBUSFUNC_Widget($w);
    return (undef, "Widget '$w' bei $n ungueltig") if(!$wd);
    $wd->{cmd} = $cmd;
    $wd->{widget} = $w if(defined $w);
    $s{$n} = $wd;
  }
  return (\%s, undef);
}

# Parses the overrideParams attribute.
# Format: <Name>:<WidgetSpec>:<DefaultValue>
# Separators are whitespace or newlines.
# Parameters:
#   $txt - Attribute value
# Returns:
#   (\%params, undef) on success, (undef, $error) on failure
sub EBUSFUNC_ParseParams($) {
  my ($txt) = @_;
  my %p;
  foreach my $t (split(/\s+/, $txt // "")) {
    next if($t eq "");
    # Strict syntax check: Name:Widget:Default
    return (undef, "'$t': erwartet <Name>:<Widget>:<Vorgabe>") if($t !~ /^([A-Za-z0-9_.\-]+):(.+):([^:]+)$/);
    my ($n, $w, $d) = ($1, $2, $3);
    my $wd = EBUSFUNC_Widget($w);
    return (undef, "Widget '$w' bei $n ungueltig") if(!$wd);
    $wd->{default} = $d;
    $wd->{widget} = $w;
    # Validate the default value against the widget type.
    my $e = EBUSFUNC_Check($wd, $d);
    return (undef, "Vorgabe $d bei $n: $e") if($e);
    $p{$n} = $wd;
  }
  return (\%p, undef);
}

# Parses the overrideList attribute for special functions (e.g., Eco mode).
# Structure: <Name> [group=...] [guard=...] [base=...] [save=...] [apply=...] [end=...] [maxDuration=...]
# Uses fixed syntax to avoid eval() risks.
# Parameters:
#   $txt - Attribute value
# Returns:
#   (\%overrides, undef) on success, (undef, $error) on failure
sub EBUSFUNC_ParseOverrides($) {
  my ($txt) = @_;
  my %o;
  foreach my $l (EBUSFUNC_Lines($txt)) {
    my ($n, @kv) = split(/\s+/, $l);
    return (undef, "Name '$n' ungueltig") if($n !~ /^[A-Za-z0-9_.\-]+$/);
    my %d = (name => $n);
    foreach my $t (@kv) {
      # Allowed keys: group, guard, base, save, apply, end, maxDuration.
      return (undef, "$n: '$t' ist kein key=value") if($t !~ /^(group|guard|base|save|apply|end|maxDuration)=(.+)$/);
      my ($k, $v) = ($1, $2);
      if($k eq "guard") {
        # Guard conditions: <Reading>:<Regex>. Must match for the function to activate.
        foreach my $c (split(/,(?=[A-Za-z0-9_.\-]+:)/, $v)) {
          return (undef, "$n guard '$c': erwartet <Reading>:<Regex>") if($c !~ /^([A-Za-z0-9_.\-]+):(.+)$/);
          my ($r, $re) = ($1, $2);
          eval { qr/$re/ }; return (undef, "$n guard: Regex '$re' ungueltig") if($@);
          push @{$d{guard}}, [$r, $re];
        }
      } elsif($k eq "save") {
        # List of readings to save before activation (for restoration).
        $d{save} = [split(/,/, $v)];
        foreach my $r (@{$d{save}}) {
          return (undef, "$n save: Name '$r' ungueltig") if($r !~ /^[A-Za-z0-9_.\-]+$/);
        }
      } elsif($k eq "apply" || ($k eq "end" && $v ne "restore")) {
        # Apply/End actions: <Command>:<Expression>.
        foreach my $c (split(/,/, $v)) {
          return (undef, "$n $k '$c': erwartet <Befehl>:<Ausdruck>") if($c !~ /^([A-Za-z0-9_.\-]+):(.+)$/);
          push @{$d{$k}}, [$1, $2];
        }
      } elsif($k eq "end") {
        # Special case: end=restore triggers restoration of saved values.
        $d{restore} = 1;
      } elsif($k eq "maxDuration") {
        # Safety timeout in minutes. Prevents stuck states if 'end' is never called.
        return (undef, "$n maxDuration muss Minuten > 0 sein") if($v !~ /^[0-9]+$/ || $v == 0);
        $d{maxDuration} = $v;
      } else {                                  # group, base: simple names/values
        return (undef, "$n $k: Name '$v' ungueltig") if($v !~ /^[A-Za-z0-9_.\-]+$/);
        $d{$k} = $v;
      }
    }
    # apply is mandatory to ensure some action is taken.
    return (undef, "$n: apply fehlt") if(!$d{apply});
    # If restoring, we must have saved values.
    return (undef, "$n: end=restore braucht save=") if($d{restore} && !$d{save});
    # Default group is the function name itself.
    $d{group} //= $n;
    $o{$n} = \%d;
  }
  return (\%o, undef);
}

# --- Spiegeln ----------------------------------------------------------------
# Formats a value according to a specified printf format if it is a valid number.
# Parameters:
#   $fmt - Format string
#   $v   - Value
# Returns:
#   Formatted string or original value
sub EBUSFUNC_Format($$) {
  my ($fmt, $v) = @_;
  return $v if(!defined $fmt || !defined $v || $v !~ $EBUSFUNC_NUM);
  return sprintf($fmt, $v);
}

# Notification handler: Mirrors readings from the parent ebus device to this device.
# Only writes to FHEM if the value actually changed (reduces event flood).
# Parameters:
#   $hash - Device hash reference
#   $dev  - Source device hash reference
# Returns:
#   None
sub EBUSFUNC_Notify($$) {
  my ($hash, $dev) = @_;
  my $name = $hash->{NAME};
  my $dn = $dev->{NAME};
  my $events = deviceEvents($dev, 0) || [];
  # Handle global events (initialization or config reload).
  if($dn eq "global") {
    EBUSFUNC_Start($hash) if(grep { /^(INITIALIZED|REREADCFG)$/ } @{$events});
    return undef;
  }
  # Ignore if not the expected parent device or if disabled.
  return undef if($dn ne $hash->{EBUSDEV} || IsDisabled($name));
  my $map = $hash->{helper}{map};
  my $n = 0;
  readingsBeginUpdate($hash);
  foreach my $ev (@{$events}) {
    # Parse "ReadingName: Value"
    next if($ev !~ /^([^:\s]+):\s(.*)$/s);
    my ($r, $v) = ($1, $2);
    next if(!$map->{$r});
    foreach my $z (@{$map->{$r}}) {
      my $nv = EBUSFUNC_Format($z->[1], $v);
      # Skip update if value hasn't changed.
      next if(ReadingsVal($name, $z->[0], "\x00") eq $nv);
      readingsBulkUpdate($hash, $z->[0], $nv);
      $n++;
    }
  }
  readingsEndUpdate($hash, 1);
  return undef;
}

# Synchronizes all mapped readings from the parent device to this device.
# Used during start or after config changes.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_SyncAll($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $map = $hash->{helper}{map} || {};
  readingsBeginUpdate($hash);
  foreach my $r (sort keys %{$map}) {
    my $v = ReadingsVal($hash->{EBUSDEV}, $r, undef);
    next if(!defined $v);
    foreach my $z (@{$map->{$r}}) {
      my $nv = EBUSFUNC_Format($z->[1], $v);
      readingsBulkUpdate($hash, $z->[0], $nv) if(ReadingsVal($name, $z->[0], "\x00") ne $nv);
    }
  }
  readingsEndUpdate($hash, 1);
}

# Checks for missing source readings defined in readingMap and logs warnings.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_MapWarnings($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  # Find source readings that do not exist in the parent device.
  my @f = grep { !defined ReadingsVal($hash->{EBUSDEV}, $_, undef) } sort keys %{$hash->{helper}{map} || {}};
  my $txt = @f ? "fehlt am $hash->{EBUSDEV}: " . join(", ", @f) : "-";
  Log3 $name, 2, "EBUSFUNC $name: readingMap - $txt" if(@f);
  readingsSingleUpdate($hash, "mapWarnings", $txt, 1) if(ReadingsVal($name, "mapWarnings", "") ne $txt);
}

# Sets default values for override parameters if they are not already defined.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_ParamDefaults($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $p = $hash->{helper}{par} || {};
  foreach my $n (sort keys %{$p}) {
    readingsSingleUpdate($hash, $n, $p->{$n}{default}, 1) if(!defined ReadingsVal($name, $n, undef));
  }
}

# --- Pruefen / Normalisieren ---------------------------------------------------
# Formats a number with a specific number of decimal places.
# Parameters:
#   $d - Widget definition (contains 'dec')
#   $x - Number
# Returns:
#   Formatted string
sub EBUSFUNC_Fmt($$) {
  my ($d, $x) = @_;
  return sprintf("%.$d->{dec}f", $x);
}

# Resolves slider limits which can be static numbers or dynamic parameter names.
# Parameters:
#   $hash - Device hash reference (needed to fetch current parameter values)
#   $d    - Widget definition
# Returns:
#   ($min, $max, $err)
sub EBUSFUNC_Range($$) {
  my ($hash, $d) = @_;
  my @r;
  foreach my $x ($d->{min}, $d->{max}) {
    if($x =~ $EBUSFUNC_NUM) { push @r, $x; next; }
    # If not a number, treat as parameter name.
    my $p = $hash ? $hash->{helper}{par}{$x} : undef;
    return (undef, undef, "Grenze '$x' ist kein Parameter") if(!$p);
    # Fetch current value of the parameter.
    my $v = ReadingsVal($hash->{NAME}, $x, $p->{default});
    return (undef, undef, "Parameter $x = '$v' keine Zahl") if($v !~ $EBUSFUNC_NUM);
    push @r, $v;
  }
  return (@r, undef);
}

# Strict validation of a value against a widget definition (used for manual 'set' commands).
# Parameters:
#   $d    - Widget definition
#   $v    - Value to check
#   $hash - Device hash reference (optional, for resolving dynamic ranges)
# Returns:
#   Error string if invalid, undef if valid
sub EBUSFUNC_Check($$;$) {
  my ($d, $v, $hash) = @_;
  my $t = $d->{type};
  if($t eq "noArg") {
    return "erwartet keinen Wert" if(defined $v && $v ne "");
    return undef;
  }
  return "Wert fehlt" if(!defined $v || $v eq "");
  return undef if($t eq "free");
  if($t eq "enum") {
    return "'$v' nicht erlaubt (" . join(",", @{$d->{values}}) . ")" if(!grep { $_ eq $v } @{$d->{values}});
    return undef;
  }
  # For sliders/numbers:
  # Accept comma as decimal separator.
  $v =~ s/,/./;
  return "'$v' ist keine Zahl" if($v !~ $EBUSFUNC_NUM);
  my ($min, $max, $err) = EBUSFUNC_Range($hash, $d);
  return $err if($err);
  # Check range with small epsilon for float comparison.
  return "'$v' ausserhalb $min..$max" if($v < $min - 1e-9 || $v > $max + 1e-9);
  # Check step grid.
  my $k = ($v - $min) / $d->{step};
  return "'$v' nicht im Raster $d->{step}" if(abs($k - int($k + 0.5)) > 1e-6);
  return undef;
}

# Lenient normalization for calculated values (e.g., from override expressions).
# Rounds to the nearest step and clamps to min/max.
# Parameters:
#   $d    - Widget definition
#   $v    - Value
#   $hash - Device hash reference
# Returns:
#   Normalized string or undef
sub EBUSFUNC_Normalize($$;$) {
  my ($d, $v, $hash) = @_;
  return $v if($d->{type} ne "slider");
  return undef if(!defined $v || $v !~ $EBUSFUNC_NUM);
  my ($min, $max, $err) = EBUSFUNC_Range($hash, $d);
  return undef if($err);
  # Round to nearest step.
  my $k = int(($v - $min) / $d->{step} + ($v >= $min ? 0.5 : -0.5));
  my $x = $min + $k * $d->{step};
  # Clamp to bounds.
  $x = $min if($x < $min);
  $x = $max if($x > $max);
  return EBUSFUNC_Fmt($d, $x);
}

# Compares two values (numbers or strings) for equality with float tolerance.
# Parameters:
#   $a - Value A
#   $b - Value B
# Returns:
#   1 if equal, 0 if different
sub EBUSFUNC_Same($$) {
  my ($a, $b) = @_;
  return 0 if(!defined $a || !defined $b);
  return abs($a - $b) < 1e-6 if($a =~ $EBUSFUNC_NUM && $b =~ $EBUSFUNC_NUM);
  return $a eq $b;
}

# --- Senden ------------------------------------------------------------------
# Sends a command to the parent ebus device via CommandSet.
# Prevents duplicate sends if the value hasn't changed.
# Blocks values containing control characters or command separators (';').
# Parameters:
#   $hash  - Device hash reference
#   $n     - Command name (from setMap)
#   $v     - Value to send
#   $note  - Optional note for logging/readings
# Returns:
#   Error string on failure, undef on success
sub EBUSFUNC_Send($$$;$) {
  my ($hash, $n, $v, $note) = @_;
  my $zus = $note ? " ($note)" : "";
  my $name = $hash->{NAME};
  my $d = $hash->{helper}{set}{$n};
  return "unbekannter Befehl $n" if(!$d);
  # IsDisabled check ensures timers also respect the 'disable' attribute.
  return "$name ist deaktiviert" if(IsDisabled($name));
  # Optimization: Skip sending if the value is identical to the current reading.
  if($d->{type} ne "noArg" && EBUSFUNC_Same(ReadingsVal($name, $n, undef), $v)) {
    readingsBeginUpdate($hash);
    readingsBulkUpdate($hash, "lastCmd", "unveraendert: $n = $v$zus");
    readingsBulkUpdate($hash, "lastCmdTime", TimeNow());
    readingsEndUpdate($hash, 1);
    return undef;
  }
  # Security: Reject values with command separators or control chars to prevent injection.
  return "Wert enthaelt unzulaessige Zeichen" if(defined $v && $v =~ /[;\x00-\x1f\x7f]/);
  my $arg = "$hash->{EBUSDEV} $d->{cmd}" . ($d->{type} eq "noArg" ? "" : " $v");
  my $cmd = "set $arg";
  Log3 $name, 3, "EBUSFUNC $name: $cmd";
  # CommandSet instead of fhem(): executes exactly ONE set command - no ';' command chaining and no
  # Perl evaluation, so a value can never inject a second FHEM command.
  my $ret = CommandSet(undef, $arg);
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "lastCmd", ($ret ? "FEHLER: $cmd - $ret" : "gesendet: $cmd$zus"));
  readingsBulkUpdate($hash, "lastCmdTime", TimeNow());
  readingsEndUpdate($hash, 1);
  Log3 $name, 1, "EBUSFUNC $name: $cmd - $ret" if($ret);
  return $ret ? "$cmd: $ret" : undef;
}

# --- Ausdruecke (feste Syntax, kein eval) ----------------------------------------
# Evaluates a fixed-syntax expression for override functions.
# Supported: "base", "base+N", "base-N", "base+Param", "base-Param", or literal value.
# Avoids eval() for security and performance.
# Parameters:
#   $hash  - Device hash reference
#   $expr  - Expression string
#   $base  - Base value (from saved reading)
# Returns:
#   ($result, $error)
sub EBUSFUNC_Expr($$$) {
  my ($hash, $expr, $base) = @_;
  my $name = $hash->{NAME};
  if($expr =~ /^base(?:\s*([+-])\s*(\S+))?$/) {
    my ($op, $arg) = ($1, $2);
    return (undef, "keine gueltige Basis") if(!defined $base || $base !~ $EBUSFUNC_NUM);
    return ($base, undef) if(!defined $op);
    my $z = $arg;
    # If offset is not a number, treat it as a parameter name.
    if($arg !~ $EBUSFUNC_NUM) {
      return (undef, "unbekannter Parameter '$arg'") if(!$hash->{helper}{par}{$arg});
      $z = ReadingsVal($name, $arg, $hash->{helper}{par}{$arg}{default});
      return (undef, "Parameter $arg = '$z' keine Zahl") if($z !~ $EBUSFUNC_NUM);
    }
    return ($op eq "+" ? $base + $z : $base - $z, undef);
  }
  # Fallback: literal value.
  return ($expr, undef);
}

# --- Sonderfunktionen ------------------------------------------------------------
# Logs the current status of override functions and updates internal readings.
# Parameters:
#   $hash - Device hash reference
#   $txt  - Status message
# Returns:
#   None
sub EBUSFUNC_Info($$) {
  my ($hash, $txt) = @_;
  my $name = $hash->{NAME};
  # List all active override functions.
  my @act = grep { ReadingsVal($name, $_, "aus") eq "an" } sort keys %{$hash->{helper}{ovr}};
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "overrideInfo", $txt);
  readingsBulkUpdate($hash, "overrideActive", @act ? join(",", @act) : "-");
  readingsEndUpdate($hash, 1);
  Log3 $name, 3, "EBUSFUNC $name: $txt";
}

# Checks if any other function in the same group is currently active.
# Parameters:
#   $hash  - Device hash reference
#   $g     - Group name
#   $ohne  - Name of the function to exclude
# Returns:
#   List of active function names
sub EBUSFUNC_GroupActive($$$) {
  my ($hash, $g, $ohne) = @_;
  my $name = $hash->{NAME};
  return grep { $_ ne $ohne && $hash->{helper}{ovr}{$_}{group} eq $g && ReadingsVal($name, $_, "aus") eq "an" }
         sort keys %{$hash->{helper}{ovr}};
}

# Activates or deactivates a special function (override).
# Handles group exclusivity, guard conditions, saving/restoring values, and timers.
# Parameters:
#   $hash   - Device hash reference
#   $on     - Function name
#   $val    - "an" or "aus"
#   $grund  - Reason for change (for logging)
# Returns:
#   Error message or undef
sub EBUSFUNC_Override($$$;$) {
  my ($hash, $on, $val, $grund) = @_;
  my $name = $hash->{NAME};
  my $o = $hash->{helper}{ovr}{$on};
  # If the function was removed from config but timer is still active, handle gracefully.
  return "unbekannte Sonderfunktion $on" if(!$o);
  my $g = $o->{group};
  my $cur = ReadingsVal($name, $on, "aus");

  if($val eq "an") {
    return undef if($cur eq "an");
    # Find other active functions in the same group to deactivate them.
    my @andere = EBUSFUNC_GroupActive($hash, $g, $on);
    if(!@andere) {
      # If this is the first function in the group, check guard conditions.
      foreach my $c (@{$o->{guard} || []}) {
        my $v = ReadingsVal($name, $c->[0], "");
        if($v !~ /$c->[1]/) {
          readingsSingleUpdate($hash, $on, "aus", 1) if(!defined ReadingsVal($name, $on, undef));
          EBUSFUNC_Info($hash, "ignoriert: $on ($c->[0]=$v)");
          return undef;
        }
      }
      # Save the base value only when the group starts (no other function active). Keeping it while
      # switching between functions of the same group prevents offsets from adding up.
      if($o->{base}) {
        my $b = ReadingsVal($name, $o->{base}, "");
        if($b !~ $EBUSFUNC_NUM) {
          EBUSFUNC_Info($hash, "ignoriert: $on (Basis $o->{base}='$b')");
          return undef;
        }
        # Use a group-specific key to avoid conflicts and allow restoration.
        readingsSingleUpdate($hash, "saved_${g}_base", $b, 1);
      }
      # Save other readings listed in 'save'.
      foreach my $r (@{$o->{save} || []}) {
        readingsSingleUpdate($hash, "saved_${g}_$r", ReadingsVal($name, $r, ""), 1);
      }
    }
    readingsBeginUpdate($hash);
    # Deactivate other active functions in the group ("last one wins").
    foreach my $a (@andere) {
      readingsBulkUpdate($hash, $a, "aus");
      EBUSFUNC_StopTimer($hash, $a);
    }
    readingsBulkUpdate($hash, $on, "an");
    readingsEndUpdate($hash, 1);
    # Retrieve base value for expression evaluation.
    my $base = ReadingsVal($name, "saved_${g}_base", undef);
    my @fehler = EBUSFUNC_Apply($hash, $o->{apply}, $base);
    # Start timeout timer if maxDuration is defined.
    EBUSFUNC_StartTimer($hash, $on) if($o->{maxDuration});
    EBUSFUNC_Info($hash, @fehler ? "aktiv mit Fehlern: $on - " . join("; ", @fehler)
                                : "aktiv: $on" . (@andere ? " (abgeloest: " . join(",", @andere) . ")" : ""));
    return undef;
  }

  # --- Deactivation ---
  return undef if($cur ne "an");
  readingsSingleUpdate($hash, $on, "aus", 1);
  EBUSFUNC_StopTimer($hash, $on);
  # If other functions in the group are still active, don't perform end/restore actions.
  if(EBUSFUNC_GroupActive($hash, $g, $on)) {
    EBUSFUNC_Info($hash, "beendet: $on" . ($grund ? " ($grund)" : "") . " - weiter aktiv in Gruppe");
    return undef;
  }
  # No other active functions in group: perform cleanup.
  my @fehler;
  if($o->{restore}) {
    # Restore saved readings.
    foreach my $r (@{$o->{save}}) {
      my $sv = ReadingsVal($name, "saved_${g}_$r", undef);
      next if(!defined $sv || !$hash->{helper}{set}{$r});
      # Normalize and validate before sending.
      my $nv = EBUSFUNC_Normalize($hash->{helper}{set}{$r}, $sv, $hash);
      my $e = !defined $nv ? "gesicherter Wert '$sv' ungueltig"
            : (EBUSFUNC_Check($hash->{helper}{set}{$r}, $nv, $hash) // EBUSFUNC_Send($hash, $r, $nv));
      push @fehler, "$r: $e" if($e);
    }
  } elsif($o->{end}) {
    # Execute custom end commands.
    @fehler = EBUSFUNC_Apply($hash, $o->{end}, ReadingsVal($name, "saved_${g}_base", undef));
  }
  # Delete all saved values for this group.
  foreach my $r (grep { /^saved_\Q$g\E_/ } keys %{$hash->{READINGS}}) {
    readingsDelete($hash, $r);
  }
  EBUSFUNC_Info($hash, (@fehler ? "beendet mit Fehlern: $on - " . join("; ", @fehler) : "beendet: $on")
                       . ($grund ? " ($grund)" : ""));
  return undef;
}

# Applies a list of command/expression pairs (for apply or end actions).
# Parameters:
#   $hash  - Device hash reference
#   $list  - Arrayref of [command, expression]
#   $base  - Base value for expressions
# Returns:
#   List of error messages
sub EBUSFUNC_Apply($$$) {
  my ($hash, $list, $base) = @_;
  my @fehler;
  foreach my $c (@{$list || []}) {
    my ($n, $expr) = @{$c};
    my $d = $hash->{helper}{set}{$n};
    if(!$d) { push @fehler, "$n: nicht in setMap"; next; }
    my ($v, $e) = EBUSFUNC_Expr($hash, $expr, $base);
    if($e) { push @fehler, "$n: $e"; next; }
    my ($nv, $note) = ($v, undef);
    # If the target is a slider, adjust the calculated value to the grid/range.
    if($d->{type} eq "slider") {
      ($nv, $note, $e) = EBUSFUNC_Adjust($hash, $n, $d, $v, "berechnet");
      if($e) { push @fehler, "$n: $e"; next; }
    }
    $e = EBUSFUNC_Check($d, $nv, $hash);
    if($e) { push @fehler, "$n: $e"; next; }
    $e = EBUSFUNC_Send($hash, $n, $nv, $note);
    push @fehler, "$n: $e" if($e);
  }
  return @fehler;
}

# --- Hoechstdauer ------------------------------------------------------------------
# Starts the timeout timer for an override function.
# Stores the end time in a reading to survive FHEM restarts.
# Parameters:
#   $hash - Device hash reference
#   $on   - Function name
# Returns:
#   None
sub EBUSFUNC_StartTimer($$) {
  my ($hash, $on) = @_;
  my $ende = gettimeofday() + 60 * $hash->{helper}{ovr}{$on}{maxDuration};
  readingsSingleUpdate($hash, "${on}_Ende", FmtDateTime($ende), 1);
  EBUSFUNC_SetTimer($hash, $on, $ende);
}

# Sets or restarts the internal timer for an override function.
# Parameters:
#   $hash - Device hash reference
#   $on   - Function name
#   $ende - End time (epoch seconds)
# Returns:
#   None
sub EBUSFUNC_SetTimer($$$) {
  my ($hash, $on, $ende) = @_;
  # Stop any existing timer first.
  EBUSFUNC_StopTimer($hash, $on, 1);
  my $arg = { hash => $hash, on => $on };
  $hash->{helper}{timer}{$on} = $arg;
  InternalTimer($ende, "EBUSFUNC_Timeout", $arg, 0);
}

# Stops the internal timer for an override function and optionally deletes the end time reading.
# Parameters:
#   $hash    - Device hash reference
#   $on      - Function name
#   $nurTimer - If true, only remove timer, keep reading (used for restart logic)
# Returns:
#   None
sub EBUSFUNC_StopTimer($$;$) {
  my ($hash, $on, $nurTimer) = @_;
  my $arg = delete $hash->{helper}{timer}{$on};
  RemoveInternalTimer($arg) if($arg);
  readingsDelete($hash, "${on}_Ende") if(!$nurTimer && defined ReadingsVal($hash->{NAME}, "${on}_Ende", undef));
}

# Timer callback: Automatically deactivates the function when maxDuration expires.
# Parameters:
#   $arg - Argument hashref from InternalTimer
# Returns:
#   None
sub EBUSFUNC_Timeout($) {
  my ($arg) = @_;
  my $hash = $arg->{hash};
  delete $hash->{helper}{timer}{$arg->{on}};
  EBUSFUNC_Override($hash, $arg->{on}, "aus", "Hoechstdauer");
}

# Restores timeout timers after FHEM restart.
# Checks if the function is active and if the stored end time is still valid.
# Parameters:
#   $hash - Device hash reference
# Returns:
#   None
sub EBUSFUNC_RestoreTimers($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  foreach my $on (sort keys %{$hash->{helper}{ovr} || {}}) {
    next if(!$hash->{helper}{ovr}{$on}{maxDuration} || ReadingsVal($name, $on, "aus") ne "an");
    my $e = ReadingsVal($name, "${on}_Ende", "");
    # If no end time saved, start a new timer.
    if($e eq "") { EBUSFUNC_StartTimer($hash, $on); next; }
    # Parse the end time. If invalid, restart timer.
    my $t = ($e =~ /^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$/) ? time_str2num($e) : undef;
    if(!defined $t) { EBUSFUNC_StartTimer($hash, $on); next; }
    # If timeout has already passed, deactivate immediately.
    if($t <= gettimeofday()) { EBUSFUNC_Override($hash, $on, "aus", "Hoechstdauer"); }
    else { EBUSFUNC_SetTimer($hash, $on, $t); }
  }
}

# Prepares a value from external input (e.g., FHEMWEB) for processing.
# Sliders: Rounds to grid and clamps to range (lenient).
# Enums/noArg: Strict validation.
# Parameters:
#   $hash - Device hash reference
#   $n    - Parameter name
#   $d    - Widget definition
#   $v    - Input value
# Returns:
#   ($value, $note, $error)
sub EBUSFUNC_Prepare($$$$) {
  my ($hash, $n, $d, $v) = @_;
  if($d->{type} eq "slider") {
    $v = "" if(!defined $v);
    $v =~ s/,/./;
    return (undef, undef, "'$v' ist keine Zahl") if($v !~ $EBUSFUNC_NUM);
    my ($nv, $note, $err) = EBUSFUNC_Adjust($hash, $n, $d, $v, "Vorgabe");
    return (undef, undef, $err) if($err);
    return ($nv, $note, undef);
  }
  my $e = EBUSFUNC_Check($d, $v, $hash);
  return (undef, undef, $e) if($e);
  return ($v, undef, undef);
}

# Adjusts a slider value to the nearest step within the allowed range.
# If out of range, clamps to min/max and logs a warning.
# Parameters:
#   $hash - Device hash reference
#   $n    - Parameter name
#   $d    - Widget definition
#   $v    - Input value
#   $art  - Context description for logging
# Returns:
#   ($adjusted_value, $note, $error)
sub EBUSFUNC_Adjust($$$$$) {
  my ($hash, $n, $d, $v, $art) = @_;
  my ($min, $max, $err) = EBUSFUNC_Range($hash, $d);
  return (undef, undef, $err) if($err);
  my $nv = EBUSFUNC_Normalize($d, $v, $hash);
  return (undef, undef, "'$v' ungueltig") if(!defined $nv);
  my $note;
  # If value was outside the range, add a note and warning.
  if($v < $min - 1e-9 || $v > $max + 1e-9) {
    $note = "begrenzt auf " . ($v < $min ? "min $min" : "max $max") . " ($art $v)";
    EBUSFUNC_Warn($hash, "$n: $note");
  }
  return ($nv, $note, undef);
}

# Logs a warning and updates the lastWarning reading.
# Parameters:
#   $hash - Device hash reference
#   $txt  - Warning message
# Returns:
#   None
sub EBUSFUNC_Warn($$) {
  my ($hash, $txt) = @_;
  Log3 $hash->{NAME}, 2, "EBUSFUNC $hash->{NAME}: Warnung - $txt";
  readingsSingleUpdate($hash, "lastWarning", $txt, 1);
}

# Generates the widget text for FHEMWEB, replacing dynamic parameter limits with current values.
# Parameters:
#   $hash - Device hash reference
#   $d    - Widget definition
# Returns:
#   Widget string
sub EBUSFUNC_WidgetText($$) {
  my ($hash, $d) = @_;
  return $d->{widget} if($d->{type} ne "slider");
  my ($min, $max, $err) = EBUSFUNC_Range($hash, $d);
  return $d->{widget} if($err);
  # Replace the min/max placeholders in the original widget string with resolved values.
  (my $rest = $d->{widget}) =~ s/^slider,[^,]+,[^,]+,[^,]+//;
  return "slider,$min,$d->{step},$max$rest";
}

# --- Set -----------------------------------------------------------------------
# Main entry point for 'set' commands.
# Routes commands to override functions, parameters, or setMap commands.
# Parameters:
#   $hash  - Device hash reference
#   $name  - Device name
#   $n     - Command name
#   @args  - Arguments
# Returns:
#   Error message or undef
sub EBUSFUNC_Set($@) {
  my ($hash, $name, $n, @args) = @_;
  return "\"set $name\" braucht ein Argument" if(!defined $n);
  # Join arguments, handling potential undefs from internal calls.
  my $v = join(" ", map { $_ // "" } @args);
  my ($s, $o, $p) = @{$hash->{helper}}{qw(set ovr par)};
  # Help command: list all available options.
  if($n eq "?") {
    my @l;
    push @l, map { $s->{$_}{widget} ? "$_:" . EBUSFUNC_WidgetText($hash, $s->{$_}) : $_ } sort keys %{$s};
    push @l, map { "$_:an,aus" } sort keys %{$o};
    push @l, map { "$_:$p->{$_}{widget}" } sort keys %{$p};
    return "Unknown argument ?, choose one of " . join(" ", @l);
  }
  return "$name ist deaktiviert" if(IsDisabled($name));
  # 1. Check if it's an override function (special mode).
  if($o->{$n}) {
    return "$name $n: an oder aus" if($v ne "an" && $v ne "aus");
    return EBUSFUNC_Override($hash, $n, $v);
  }
  # 2. Check if it's an override parameter (setting a value).
  if($p->{$n}) {
    my ($nv, $note, $e) = EBUSFUNC_Prepare($hash, $n, $p->{$n}, $v);
    return "$name $n: $e" if($e);
    readingsSingleUpdate($hash, $n, $nv, 1);
    Log3 $name, 3, "EBUSFUNC $name: $n = $nv ($note)" if($note);
    return undef;
  }
  # 3. Check if it's a setMap command (send to bus).
  if($s->{$n}) {
    my ($nv, $note, $e) = EBUSFUNC_Prepare($hash, $n, $s->{$n}, $v);
    return "$name $n: $e" if($e);
    return EBUSFUNC_Send($hash, $n, $nv, $note);
  }
  # Fallback: Unknown command.
  return "Unknown argument $n, choose one of " . join(" ", sort(keys %{$s}, keys %{$o}, keys %{$p}));
}

1;

=pod
=item device
=item summary    function block on top of an ebusd device (mirror, write, overrides)
=item summary_DE Funktionsblock ueber einem ebusd-Device (spiegeln, schreiben, Sonderfunktionen)
=begin html

<a id="EBUSFUNC"></a>
<h3>EBUSFUNC</h3>
<ul>
  EBUSFUNC creates a <b>functional block</b> (e.g. a heating circuit, domestic hot water, or heat pump) on top of an existing ebusd device. The ebusd device is typically an MQTT2_DEVICE that contains the values published by ebusd via MQTT as readings. EBUSFUNC
  <ul>
    <li><b>mirrors</b> selected values with short, descriptive names (<i>readingMap</i>),</li>
    <li>provides validated <b>control commands</b> that are passed on to the ebusd device (<i>setMap</i>),</li>
    <li>provides <b>override functions</b> that <b>temporarily</b> change settings and then restore them (<i>overrideList</i>, <i>overrideParams</i>).</li>
  </ul>
  Everything that is specific to the system is stored in attributes; the module itself does not know any manufacturer or parameter names. Nonsensical inputs (text instead of numbers, units, control characters, broken attributes) lead to error messages, never to a crash of FHEM or an unvalidated write command.<br><br>

  <a id="EBUSFUNC-define"></a><b>Define</b>
  <ul>
    <code>define &lt;name&gt; EBUSFUNC &lt;ebusDevice&gt;</code><br>
    <i>ebusDevice</i> is the FHEM device with the ebusd readings, e.g. <code>ebusWP</code>.
  </ul><br>

  <a id="EBUSFUNC-namen"></a><b>Where do the names come from?</b>
  <ul>
    <li><b>Source readings</b> (first column of the <i>readingMap</i>): exactly the reading names of the ebusd device, as they appear in its device view or with <code>list &lt;ebusDevice&gt;</code>. They are created from the message names of the ebusd configuration (CSV files of the controller; MQTT topic <code>ebusd/&lt;circuit&gt;/&lt;message&gt;</code>). If a name is missing, EBUSFUNC reports this in the <i>mapWarnings</i> reading.</li>
    <li><b>Target commands</b> (second column of the <i>setMap</i>): the set commands of the ebusd device, see <code>set &lt;ebusDevice&gt; ?</code> or its <i>setList</i> attribute. EBUSFUNC never writes to the bus itself, but calls exactly this set command. Checking, pauses and reading back during writing is done by the writing path of the ebusd device (e.g. a helper module with a whitelist).</li>
    <li><b>Limits and steps</b> (widgets of the <i>setMap</i>): from the manual or the controller's operating panel and the writing path. They should never be wider than allowed there.</li>
  </ul><br>

  <a id="EBUSFUNC-set"></a><b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; &lt;command&gt; &lt;value&gt;</code> - each entry of the <i>setMap</i>. Selection lists are strictly checked. Numbers in slider widgets are silently rounded to the grid within the range (22.44 -> 22.5); outside the range, the limit value is set and a warning is issued (reading <i>lastWarning</i>, log level 2). Comma and period are allowed as decimal separators. If the mirrored reading with the same name already has the value, nothing is sent (<i>lastCmd</i> "unchanged").</li>
    <li><code>set &lt;name&gt; &lt;override function&gt; an|aus</code> - each entry of the <i>overrideList</i>.</li>
    <li><code>set &lt;name&gt; &lt;parameter&gt; &lt;value&gt;</code> - each entry of the <i>overrideParams</i> (same rounding/limiting as above).</li>
  </ul><br>

  <a id="EBUSFUNC-attr"></a><b>Attributes</b>
  <ul>
    <li><a id="EBUSFUNC-attr-readingMap"></a><b>readingMap</b> - one line per value:
      <code>&lt;source reading&gt; &lt;target reading&gt; [&lt;format&gt;]</code>.<br>
      Format is optional, only simple printf formats for numbers (<code>%.1f</code>, <code>%d</code>, <code>%s</code>).
      All events of a packet are processed; only written when changed. Target names must not be internal readings (lastCmd, overrideActive, saved_* ...).</li>
    <li><a id="EBUSFUNC-attr-setMap"></a><b>setMap</b> - one line per command:
      <code>&lt;name&gt;[:&lt;widget&gt;] &lt;target command&gt;</code>.<br>
      Widget: selection list (<code>a,b,c</code>), <code>slider,min,step,max</code> or <code>noArg</code>.
      <i>min</i>/<i>max</i> may name a parameter from <i>overrideParams</i> instead of a number; then its current value applies (e.g. a personal maximum flow temperature <code>VL_Max</code>). Tip: name the command the same as the mirrored reading, then the check "unchanged" applies.</li>
    <li><a id="EBUSFUNC-attr-overrideParams"></a><b>overrideParams</b> -
      <code>&lt;name&gt;:&lt;widget&gt;:&lt;default&gt; ...</code> (separated by spaces). Adjustable values that are used in the <i>overrideList</i> (e.g. as an offset) or as a slider limit in the <i>setMap</i>. They are stored as readings in the device, survive a restart and can be changed with <code>set</code>.</li>
    <li><a id="EBUSFUNC-attr-overrideList"></a><b>overrideList</b> - one line per override function:
      <code>&lt;name&gt; key=value ...</code>. The keys:
      <ul>
        <li><b>group=&lt;g&gt;</b> - functions of the same group exclude each other (e.g. economy mode and priority operation of the same heating circuit). If not specified, each function forms its own group.</li>
        <li><b>guard=&lt;reading&gt;:&lt;regex&gt;,...</b> - conditions that must be met at the start (all). Readings of this device are checked. If one is not met, the switch remains <i>aus</i> (off) and <i>overrideInfo</i> states the reason ("ignored: ..."). If a function of the group is already running, the switch is not checked again when changing.</li>
        <li><b>base=&lt;reading&gt;</b> - base value for calculations, e.g. the current flow setpoint of the heating curve. It is <b>only remembered at the first start in the group</b> (reading <i>saved_&lt;g&gt;_base</i>). When switching between functions of the same group, it remains, so that offsets do not add up.</li>
        <li><b>save=&lt;reading&gt;,...</b> - values to be remembered before overwriting (<i>saved_&lt;g&gt;_&lt;reading&gt;</i>), e.g. for <code>end=restore</code>.</li>
        <li><b>apply=&lt;command&gt;:&lt;expression&gt;,...</b> - what is set in this order when switching on (commands from the <i>setMap</i>). Expressions: fixed value | <code>base</code> | <code>base+&lt;number&gt;</code> | <code>base-&lt;number&gt;</code> | <code>base+&lt;parameter&gt;</code> | <code>base-&lt;parameter&gt;</code>. Calculated numbers are rounded or limited as with <i>set</i> (with warning). No Perl.</li>
        <li><b>end=&lt;command&gt;:&lt;expression&gt;,...</b> - what is set when switching off, if no other function of the group is active. <b>end=restore</b> writes the values remembered with <i>save</i> back instead.</li>
        <li><b>maxDuration=&lt;minutes&gt;</b> - optional: function ends automatically after this time (protection in case switching off is forgotten). The end time is in the reading <i>&lt;name&gt;_Ende</i> and survives a restart.</li>
      </ul></li>
    <li><b>disable</b> - 1: no commands, no mirroring, not even timer actions.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul><br>

  <a id="EBUSFUNC-override"></a><b>Override functions explained using economy mode and priority operation as examples</b>
  <ul>
    Override functions temporarily change the controller's settings and then restore them. An energy manager or a time control only needs to call <code>set &lt;name&gt; &lt;function&gt; an|aus</code> and does not need any knowledge of the controller's logic.<br><br>
    <b>Economy mode</b> (e.g. before sunrise): The heating circuit is throttled. When switching on, EBUSFUNC remembers the current flow setpoint of the heating curve, sets the manual setpoint to <i>base + Spar_Offset</i> (e.g. -6 K) and switches the circuit to manual mode. A floor heating system releases its stored heat during this time.<br>
    <b>Eigenverbrauch_Vorrang</b> (e.g. with PV surplus): The manual setpoint is raised to <i>base + EV_Offset</i> (e.g. +5 K); the screed or buffer stores the heat as a buffer ("recharge").<br>
    <b>Switching off</b>: If no function of the group is active, the circuit returns to <i>Automatik</i>; the remembered base is deleted.<br>
    <b>Switching</b>: If economy mode is switched on during priority operation (or vice versa), the last command wins; the other function is switched off without restoring, and the new setpoint is calculated from the same base.<br>
    <b>Condition</b>: With <i>guard</i>, the function only applies if, for example, the circuit is in automatic mode and is heating - not in summer or in standby.<br>
    <b>Manual commands</b> during an override function are sent immediately; when switching off, <i>end</i> is still executed.
  </ul><br>

  <a id="EBUSFUNC-readings"></a><b>Readings</b>
  <ul>
    mirrored readings (<i>readingMap</i>), parameters (<i>overrideParams</i>), one reading per override function (<i>an</i>/<i>aus</i>), <i>overrideActive</i> (active functions), <i>overrideInfo</i> (last action or reason for "ignored"), <i>saved_&lt;group&gt;_*</i> (remembered values), <i>&lt;function&gt;_Ende</i> (with maxDuration), <i>lastCmd</i> / <i>lastCmdTime</i> (last command), <i>lastWarning</i> (value limited to min/max), <i>mapWarnings</i> (missing source readings).
  </ul><br>

  <a id="EBUSFUNC-example"></a><b>Example: Heating circuit 2 of a heat pump</b>
  <ul>
    Complete configuration of a running heating circuit. The ebusd device is called <code>ebusWP</code>; the reading names come from its ebusd configuration, the commands <code>HKR2_Betriebswahl</code> and <code>HKR2_Handsoll</code> from its setList. <code>VL_Max</code> is a personal upper limit for the flow. The readings <code>VL_Ist</code>/<code>RL_Ist</code> (1-wire sensor) are set by a separate DOIF with <code>setreading</code>; the userReading <code>Spreizung</code> calculates the temperature difference from this. The userReading <code>Modus</code> and devStateIcon show temperature and operating mode with a small coloured dot in text size (Stby hollow grey, Spar blue, Auto green, Hand yellow, Vorr red). FHEMWEB only treats the result of a Perl devStateIcon as HTML if it starts with <code>&lt;</code> and ends with <code>&gt;</code>, hence the <code>&lt;div&gt;</code>.<br>
    Format as in <code>fhem.cfg</code> or in the dialog "Raw definition" (line continuation with <code>\</code>, in Perl attributes <code>;;</code>):
<pre>
define Heizung_HKR2 EBUSFUNC ebusWP
attr Heizung_HKR2 devStateIcon {my %c=(Stby=&gt;"#808080",Spar=&gt;"#2060ff",Auto=&gt;"#00b000",Hand=&gt;"#e0b000",Vorr=&gt;"#e00000");; my $m=ReadingsVal($name,"Modus","");; my $z=($m eq "Stby") ? "&amp;#9675;;" : "&amp;#9679;;";; "&lt;div&gt;&lt;span style='color:".($c{$m}//"#808080")."'&gt;$z&lt;/span&gt; ".ReadingsVal($name,"VL_Ist_eBUS","-")." &amp;deg;;C $m&lt;/div&gt;"}
attr Heizung_HKR2 overrideList Sparbetrieb group=hk guard=Betriebswahl:^Automatik$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb|Zwangsdrosselung|Heizbetrieb_aktiv)$ base=VL_Soll apply=Handsoll:base+Spar_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik\
Eigenverbrauch_Vorrang group=hk guard=Betriebswahl:^Automatik$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb|Zwangsdrosselung|Heizbetrieb_aktiv)$ base=VL_Soll apply=Handsoll:base+EV_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik
attr Heizung_HKR2 overrideParams VL_Max:slider,20,0.5,34:34 EV_Offset:slider,0,0.5,10:5 Spar_Offset:slider,-10,0.5,0:-6
attr Heizung_HKR2 readingMap Status.HKR2.02.051                      Status\
Betriebswahl.HKR2.03.050                Betriebswahl\
Sollwert.HKR2.Vorlauftemp.01.002        VL_Soll      %.1f\
Istwert.HKR2.Vorlauftemp.00.002         VL_Ist_eBUS  %.1f\
Raumsollwert.HKR2.01.001                Raumsoll     %.1f\
Solltemp.Handbetrieb.HKR2.07.009        Handsoll     %.1f\
Status.HKR2.Pumpe.01.020                Pumpe\
Mischer.HKR2.01.021                     Mischer\
Aussentemperatur.Mittelwert.HKR2.02.020 AT_Mittel    %.1f
attr Heizung_HKR2 room Heizung
attr Heizung_HKR2 setMap Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen  HKR2_Betriebswahl\
Handsoll:slider,10,0.5,VL_Max                              HKR2_Handsoll
attr Heizung_HKR2 stateFormat VL_Ist_eBUS &deg;C Modus
attr Heizung_HKR2 userReadings Spreizung:(VL_Ist|RL_Ist):.* {ReadingsVal($name,"VL_Ist","") =~ /^-?[0-9]+(\.[0-9]+)?$/ &amp;&amp; ReadingsVal($name,"RL_Ist","") =~ /^-?[0-9]+(\.[0-9]+)?$/ ? sprintf("%.1f",ReadingsVal($name,"VL_Ist",0)-ReadingsVal($name,"RL_Ist",0)) : "-"}, Modus:(Betriebswahl|Sparbetrieb|Eigenverbrauch_Vorrang):.* {ReadingsVal($name,"Sparbetrieb","aus") eq "an" ? "Spar" : ReadingsVal($name,"Eigenverbrauch_Vorrang","aus") eq "an" ? "Vorr" : ({Standbybetrieb=&gt;"Stby",Automatik=&gt;"Auto",Handbetrieb_Heizen=&gt;"Hand"}-&gt;{ReadingsVal($name,"Betriebswahl","")} // ReadingsVal($name,"Betriebswahl","?"))}
</pre>
  </ul>
</ul>

=end html

=begin html_DE

<a id="EBUSFUNC"></a>
<h3>EBUSFUNC</h3>
<ul>
  EBUSFUNC bildet einen <b>Funktionsblock</b> (z. B. einen Heizkreis, das Warmwasser oder die W&auml;rmepumpe) &uuml;ber einem
  vorhandenen ebusd-Device. Das ebusd-Device ist typischerweise ein MQTT2_DEVICE, das die von ebusd per MQTT ver&ouml;ffentlichten
  Werte als Readings enth&auml;lt. EBUSFUNC
  <ul>
    <li><b>spiegelt</b> ausgew&auml;hlte Werte unter kurzen, sprechenden Namen (<i>readingMap</i>),</li>
    <li>bietet gepr&uuml;fte <b>Bedienbefehle</b>, die an das ebusd-Device weitergereicht werden (<i>setMap</i>),</li>
    <li>stellt <b>Sonderfunktionen</b> bereit, die Einstellungen vor&uuml;bergehend &auml;ndern und danach wieder zur&uuml;ckstellen
      (<i>overrideList</i>, <i>overrideParams</i>).</li>
  </ul>
  Alles Anlagen-Spezifische steht in Attributen; das Modul selbst kennt keine Hersteller- oder Parameternamen.
  Unsinnige Eingaben (Text statt Zahl, Einheiten, Steuerzeichen, kaputte Attribute) f&uuml;hren zu Fehlermeldungen,
  nie zu einem Absturz von FHEM oder zu einem ungepr&uuml;ften Schreibbefehl.<br><br>

  <a id="EBUSFUNC-define"></a><b>Define</b>
  <ul>
    <code>define &lt;name&gt; EBUSFUNC &lt;ebusDevice&gt;</code><br>
    <i>ebusDevice</i> ist das FHEM-Device mit den ebusd-Readings, z. B. <code>ebusWP</code>.
  </ul><br>

  <a id="EBUSFUNC-namen"></a><b>Woher kommen die Namen?</b>
  <ul>
    <li><b>Quell-Readings</b> (erste Spalte der <i>readingMap</i>): genau die Reading-Namen des ebusd-Devices, wie sie in
      dessen Device-Ansicht bzw. mit <code>list &lt;ebusDevice&gt;</code> erscheinen. Sie entstehen aus den
      Nachrichtennamen der ebusd-Konfiguration (CSV-Dateien des Reglers; MQTT-Topic <code>ebusd/&lt;circuit&gt;/&lt;Nachricht&gt;</code>).
      Fehlt ein Name, meldet EBUSFUNC das im Reading <i>mapWarnings</i>.</li>
    <li><b>Ziel-Befehle</b> (zweite Spalte der <i>setMap</i>): die set-Befehle des ebusd-Devices, siehe
      <code>set &lt;ebusDevice&gt; ?</code> bzw. dessen Attribut <i>setList</i>. EBUSFUNC schreibt nie selbst auf den Bus,
      sondern ruft genau diesen set-Befehl auf. Pr&uuml;fung, Pausen und R&uuml;cklesen beim Schreiben &uuml;bernimmt der Schreibweg
      des ebusd-Devices (z. B. ein Hilfsmodul mit Whitelist).</li>
    <li><b>Grenzen und Raster</b> (Widgets der <i>setMap</i>): aus der Anleitung bzw. dem Bedienteil des Reglers und dem
      Schreibweg. Sie sollten nie weiter sein als dort erlaubt.</li>
  </ul><br>

  <a id="EBUSFUNC-set"></a><b>Set</b>
  <ul>
    <li><code>set &lt;name&gt; &lt;Befehl&gt; &lt;Wert&gt;</code> &ndash; jeder Eintrag der <i>setMap</i>. Auswahllisten werden streng
      gepr&uuml;ft. Zahlen bei slider-Widgets werden innerhalb des Bereichs still aufs Raster gerundet (22.44 &rarr; 22.5);
      au&szlig;erhalb wird der Grenzwert gesetzt und eine Warnung ausgegeben (Reading <i>lastWarning</i>, Log Level 2).
      Komma und Punkt sind als Dezimaltrenner erlaubt. Hat das gespiegelte Reading gleichen Namens den Wert schon,
      wird nichts gesendet (<i>lastCmd</i> &bdquo;unveraendert&ldquo;).</li>
    <li><code>set &lt;name&gt; &lt;Sonderfunktion&gt; an|aus</code> &ndash; jeder Eintrag der <i>overrideList</i>.</li>
    <li><code>set &lt;name&gt; &lt;Parameter&gt; &lt;Wert&gt;</code> &ndash; jeder Eintrag der <i>overrideParams</i>
      (gleiche Rundung/Begrenzung wie oben).</li>
  </ul><br>

  <a id="EBUSFUNC-attr"></a><b>Attribute</b>
  <ul>
    <li><a id="EBUSFUNC-attr-readingMap"></a><b>readingMap</b> &ndash; eine Zeile je Wert:
      <code>&lt;Quell-Reading&gt; &lt;Ziel-Reading&gt; [&lt;Format&gt;]</code>.<br>
      Format optional, nur einfache printf-Formate f&uuml;r Zahlen (<code>%.1f</code>, <code>%d</code>, <code>%s</code>).
      Alle Events eines Pakets werden verarbeitet; geschrieben wird nur bei &Auml;nderung. Ziel-Namen d&uuml;rfen keine
      internen Readings sein (lastCmd, overrideActive, saved_* &hellip;).</li>
    <li><a id="EBUSFUNC-attr-setMap"></a><b>setMap</b> &ndash; eine Zeile je Befehl:
      <code>&lt;Name&gt;[:&lt;Widget&gt;] &lt;Ziel-Befehl&gt;</code>.<br>
      Widget: Auswahlliste (<code>a,b,c</code>), <code>slider,min,schritt,max</code> oder <code>noArg</code>.
      <i>min</i>/<i>max</i> d&uuml;rfen statt einer Zahl einen Parameter aus <i>overrideParams</i> nennen; dann gilt dessen
      aktueller Wert (z. B. eine pers&ouml;nliche H&ouml;chsttemperatur <code>VL_Max</code>). Tipp: den Befehl so nennen wie das
      gespiegelte Reading, dann greift die Pr&uuml;fung &bdquo;unver&auml;ndert&ldquo;.</li>
    <li><a id="EBUSFUNC-attr-overrideParams"></a><b>overrideParams</b> &ndash;
      <code>&lt;Name&gt;:&lt;Widget&gt;:&lt;Vorgabe&gt; ...</code> (durch Leerzeichen getrennt). Einstellbare Werte, die in der
      <i>overrideList</i> (z. B. als Offset) oder als slider-Grenze in der <i>setMap</i> verwendet werden. Sie stehen als
      Readings im Device, &uuml;berstehen einen Neustart und lassen sich per <code>set</code> &auml;ndern.</li>
    <li><a id="EBUSFUNC-attr-overrideList"></a><b>overrideList</b> &ndash; eine Zeile je Sonderfunktion:
      <code>&lt;Name&gt; schl&uuml;ssel=wert ...</code>. Die Schl&uuml;ssel:
      <ul>
        <li><b>group=&lt;g&gt;</b> &ndash; Funktionen derselben Gruppe schlie&szlig;en sich aus (z. B. Spar- und Vorrangbetrieb
          desselben Heizkreises). Ohne Angabe bildet jede Funktion ihre eigene Gruppe.</li>
        <li><b>guard=&lt;Reading&gt;:&lt;Regex&gt;,...</b> &ndash; Bedingungen, die beim Start erf&uuml;llt sein m&uuml;ssen (alle).
          Gepr&uuml;ft werden Readings dieses Devices. Ist eine nicht erf&uuml;llt, bleibt der Schalter auf <i>aus</i> und
          <i>overrideInfo</i> nennt den Grund (&bdquo;ignoriert: ...&ldquo;). L&auml;uft in der Gruppe schon eine Funktion, wird
          beim Wechsel nicht erneut gepr&uuml;ft.</li>
        <li><b>base=&lt;Reading&gt;</b> &ndash; Basiswert f&uuml;r Berechnungen, z. B. der aktuelle Vorlauf-Sollwert der Heizkurve.
          Er wird <b>nur beim ersten Start in der Gruppe</b> gemerkt (Reading <i>saved_&lt;g&gt;_base</i>). Beim Wechsel
          zwischen Funktionen derselben Gruppe bleibt er erhalten, damit sich Offsets nicht aufaddieren.</li>
        <li><b>save=&lt;Reading&gt;,...</b> &ndash; Werte, die vor dem &Uuml;berschreiben gemerkt werden
          (<i>saved_&lt;g&gt;_&lt;Reading&gt;</i>), z. B. f&uuml;r <code>end=restore</code>.</li>
        <li><b>apply=&lt;Befehl&gt;:&lt;Ausdruck&gt;,...</b> &ndash; was beim Einschalten in dieser Reihenfolge gesetzt wird
          (Befehle der <i>setMap</i>). Ausdr&uuml;cke: fester Wert | <code>base</code> | <code>base+&lt;Zahl&gt;</code> |
          <code>base-&lt;Zahl&gt;</code> | <code>base+&lt;Parameter&gt;</code> | <code>base-&lt;Parameter&gt;</code>.
          Berechnete Zahlen werden wie bei <i>set</i> gerundet bzw. begrenzt (mit Warnung). Kein Perl.</li>
        <li><b>end=&lt;Befehl&gt;:&lt;Ausdruck&gt;,...</b> &ndash; was beim Ausschalten gesetzt wird, wenn keine andere
          Funktion der Gruppe mehr aktiv ist. <b>end=restore</b> schreibt stattdessen die mit <i>save</i> gemerkten Werte zur&uuml;ck.</li>
        <li><b>maxDuration=&lt;Minuten&gt;</b> &ndash; optional: Funktion endet nach dieser Zeit von selbst (Schutz, falls das
          Ausschalten vergessen wird). Die Endzeit steht im Reading <i>&lt;Name&gt;_Ende</i> und &uuml;bersteht einen Neustart.</li>
      </ul></li>
    <li><b>disable</b> &ndash; 1: keine Befehle, keine Spiegelung, auch keine Timer-Aktionen.</li>
    <li><a href="#readingFnAttributes">readingFnAttributes</a></li>
  </ul><br>

  <a id="EBUSFUNC-override"></a><b>Sonderfunktionen am Beispiel Spar- und Vorrangbetrieb</b>
  <ul>
    Sonderfunktionen &auml;ndern Einstellungen des Reglers <b>vor&uuml;bergehend</b> und stellen sie danach zur&uuml;ck. Ein
    Energiemanager oder eine Zeitsteuerung muss dazu nur <code>set &lt;name&gt; &lt;Funktion&gt; an|aus</code> aufrufen und
    braucht keine Kenntnis der Regler-Logik.<br><br>
    <b>Sparbetrieb</b> (z. B. vor Sonnenaufgang): Der Heizkreis wird gedrosselt. Beim Einschalten merkt sich EBUSFUNC den
    aktuellen Vorlauf-Sollwert der Heizkurve, stellt den Hand-Sollwert auf <i>Basis + Spar_Offset</i> (z. B. &minus;6 K) und
    schaltet den Kreis in den Handbetrieb. Eine Fu&szlig;bodenheizung gibt in dieser Zeit ihre gespeicherte W&auml;rme ab.<br>
    <b>Eigenverbrauch_Vorrang</b> (z. B. bei PV-&Uuml;berschuss): Der Hand-Sollwert wird auf <i>Basis + EV_Offset</i>
    (z. B. +5 K) angehoben; der Estrich bzw. Puffer nimmt die W&auml;rme als Speicher auf (&bdquo;nachladen&ldquo;).<br>
    <b>Ausschalten</b>: Ist keine Funktion der Gruppe mehr aktiv, geht der Kreis zur&uuml;ck in <i>Automatik</i>; die gemerkte
    Basis wird gel&ouml;scht.<br>
    <b>Wechsel</b>: Wird w&auml;hrend Sparbetrieb der Vorrang eingeschaltet (oder umgekehrt), gewinnt der letzte Befehl; die
    andere Funktion geht ohne R&uuml;ckstellung aus, und der neue Sollwert wird von derselben Basis berechnet.<br>
    <b>Bedingung</b>: Mit <i>guard</i> greift die Funktion z. B. nur, wenn der Kreis auf Automatik steht und heizt &ndash;
    nicht im Sommer oder im Standby.<br>
    <b>Manuelle Befehle</b> w&auml;hrend einer Sonderfunktion werden sofort gesendet; beim Ausschalten l&auml;uft <i>end</i> trotzdem.
  </ul><br>

  <a id="EBUSFUNC-readings"></a><b>Readings</b>
  <ul>
    gespiegelte Readings (<i>readingMap</i>), Parameter (<i>overrideParams</i>), je Sonderfunktion ein Reading
    (<i>an</i>/<i>aus</i>), <i>overrideActive</i> (aktive Funktionen), <i>overrideInfo</i> (letzte Aktion bzw. Grund f&uuml;r
    &bdquo;ignoriert&ldquo;), <i>saved_&lt;Gruppe&gt;_*</i> (gemerkte Werte), <i>&lt;Funktion&gt;_Ende</i> (bei maxDuration),
    <i>lastCmd</i> / <i>lastCmdTime</i> (letzter Befehl), <i>lastWarning</i> (Wert auf min/max begrenzt), <i>mapWarnings</i>
    (fehlende Quell-Readings).
  </ul><br>

  <a id="EBUSFUNC-example"></a><b>Beispiel: Heizkreis 2 einer W&auml;rmepumpe</b>
  <ul>
    Vollst&auml;ndige Konfiguration eines laufenden Heizkreises. Das ebusd-Device hei&szlig;t <code>ebusWP</code>; die
    Reading-Namen stammen aus dessen ebusd-Konfiguration, die Befehle <code>HKR2_Betriebswahl</code> und
    <code>HKR2_Handsoll</code> aus dessen setList. <code>VL_Max</code> ist eine pers&ouml;nliche Obergrenze f&uuml;r den Vorlauf.
    Die Readings <code>VL_Ist</code>/<code>RL_Ist</code> (1-Wire-F&uuml;hler) setzt ein separater DOIF per
    <code>setreading</code>; daraus berechnet das userReading <code>Spreizung</code> die Temperaturdifferenz. Das userReading
    <code>Modus</code> und devStateIcon zeigen Temperatur und Betriebsart mit kleinem Farbpunkt in Schriftgr&ouml;&szlig;e
    (Stby grau hohl, Spar blau, Auto gr&uuml;n, Hand gelb, Vorr rot). FHEMWEB nimmt das Ergebnis eines Perl-devStateIcon nur
    als HTML, wenn es mit <code>&lt;</code> beginnt und mit <code>&gt;</code> endet, daher das <code>&lt;div&gt;</code>.<br>
    Format wie in <code>fhem.cfg</code> bzw. im Dialog &bdquo;Raw definition&ldquo; (Zeilenfortsetzung mit <code>\</code>,
    in Perl-Attributen <code>;</code> als <code>;;</code>):
<pre>
define Heizung_HKR2 EBUSFUNC ebusWP
attr Heizung_HKR2 devStateIcon {my %c=(Stby=&gt;"#808080",Spar=&gt;"#2060ff",Auto=&gt;"#00b000",Hand=&gt;"#e0b000",Vorr=&gt;"#e00000");; my $m=ReadingsVal($name,"Modus","");; my $z=($m eq "Stby") ? "&amp;#9675;;" : "&amp;#9679;;";; "&lt;div&gt;&lt;span style='color:".($c{$m}//"#808080")."'&gt;$z&lt;/span&gt; ".ReadingsVal($name,"VL_Ist_eBUS","-")." &amp;deg;;C $m&lt;/div&gt;"}
attr Heizung_HKR2 overrideList Sparbetrieb group=hk guard=Betriebswahl:^Automatik$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb|Zwangsdrosselung|Heizbetrieb_aktiv)$ base=VL_Soll apply=Handsoll:base+Spar_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik\
Eigenverbrauch_Vorrang group=hk guard=Betriebswahl:^Automatik$,Status:^(Normal_Heizbetrieb|Spar_Heizbetrieb|Zwangsdrosselung|Heizbetrieb_aktiv)$ base=VL_Soll apply=Handsoll:base+EV_Offset,Betriebswahl:Handbetrieb_Heizen end=Betriebswahl:Automatik
attr Heizung_HKR2 overrideParams VL_Max:slider,20,0.5,34:34 EV_Offset:slider,0,0.5,10:5 Spar_Offset:slider,-10,0.5,0:-6
attr Heizung_HKR2 readingMap Status.HKR2.02.051                      Status\
Betriebswahl.HKR2.03.050                Betriebswahl\
Sollwert.HKR2.Vorlauftemp.01.002        VL_Soll      %.1f\
Istwert.HKR2.Vorlauftemp.00.002         VL_Ist_eBUS  %.1f\
Raumsollwert.HKR2.01.001                Raumsoll     %.1f\
Solltemp.Handbetrieb.HKR2.07.009        Handsoll     %.1f\
Status.HKR2.Pumpe.01.020                Pumpe\
Mischer.HKR2.01.021                     Mischer\
Aussentemperatur.Mittelwert.HKR2.02.020 AT_Mittel    %.1f
attr Heizung_HKR2 room Heizung
attr Heizung_HKR2 setMap Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen  HKR2_Betriebswahl\
Handsoll:slider,10,0.5,VL_Max                              HKR2_Handsoll
attr Heizung_HKR2 stateFormat VL_Ist_eBUS &deg;C Modus
attr Heizung_HKR2 userReadings Spreizung:(VL_Ist|RL_Ist):.* {ReadingsVal($name,"VL_Ist","") =~ /^-?[0-9]+(\.[0-9]+)?$/ &amp;&amp; ReadingsVal($name,"RL_Ist","") =~ /^-?[0-9]+(\.[0-9]+)?$/ ? sprintf("%.1f",ReadingsVal($name,"VL_Ist",0)-ReadingsVal($name,"RL_Ist",0)) : "-"}, Modus:(Betriebswahl|Sparbetrieb|Eigenverbrauch_Vorrang):.* {ReadingsVal($name,"Sparbetrieb","aus") eq "an" ? "Spar" : ReadingsVal($name,"Eigenverbrauch_Vorrang","aus") eq "an" ? "Vorr" : ({Standbybetrieb=&gt;"Stby",Automatik=&gt;"Auto",Handbetrieb_Heizen=&gt;"Hand"}-&gt;{ReadingsVal($name,"Betriebswahl","")} // ReadingsVal($name,"Betriebswahl","?"))}
</pre>
  </ul>
</ul>

=end html_DE
=cut
