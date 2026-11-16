##############################################################################
#
#  99_ebusWPUtils.pm
#  $Id$
#
#  License: GPL v2 or later (like FHEM).
#  This program is free software; you can redistribute it and/or modify it under
#  the terms of the GNU General Public License as published by the Free Software
#  Foundation; either version 2 of the License, or (at your option) any later
#  version. It is distributed WITHOUT ANY WARRANTY; see <https://www.gnu.org/licenses/>.
#  Writing to a heat pump is at your own risk.
#
#  DE: Schreibweg FHEM -> ebusd -> Waermepumpe (Schutzebene im FHEM).
#      Aufruf aus der setList des ebusd-Devices:  {ebusWP_Set($NAME,$EVENT)}
#      $EVENT = "<Befehl> <Wert>", z. B. "HKR2_Betriebswahl Automatik".
#      Schutzmassnahmen (zusaetzlich zu Whitelist/Wertelisten/ACL in ebusd):
#        - feste Whitelist je Befehl mit Pruefung von Bereich, Raster, Werten
#        - Not-Aus:  attr <ebusDevice> ebusSchreibsperre 1
#        - Warteschlange, mindestens 10 s zwischen zwei Buszugriffen
#        - Tageslimit je Befehl; gleicher Wert wie Ist -> kein Buszugriff
#        - Ausfuehrung im Kindprozess (BlockingCall): FHEM blockiert nie
#        - Ruecklesen 12 s nach dem Schreiben, Ergebnis in Schreib_Status
#        - Waechter: Warteschlange haengt nie dauerhaft
#      Anpassung an eine andere Anlage: Whitelist %EBUSWP_W (Befehlsnamen,
#      ebusd-Nachrichten, Grenzen) und Pfad zum ebusd-Geheimnis. Die Whitelist
#      unten ist ein Beispiel fuer eine Ochsner-Waermepumpe (Regler OTE3).
#
#  EN: Write path FHEM -> ebusd -> heat pump (protection layer in FHEM).
#      Called from the setList of the ebusd device:  {ebusWP_Set($NAME,$EVENT)}
#      $EVENT = "<command> <value>", e.g. "HKR2_Betriebswahl Automatik".
#      Safeguards (in addition to whitelist/value lists/ACL in ebusd):
#        - fixed whitelist per command checking range, step and values
#        - emergency stop:  attr <ebusDevice> ebusSchreibsperre 1
#        - queue, at least 10 s between two bus accesses
#        - daily limit per command; same value as current -> no bus access
#        - executed in a child process (BlockingCall): FHEM never blocks
#        - read-back 12 s after writing, result in Schreib_Status
#        - watchdog: the queue never stays blocked
#      Adapting to another installation: whitelist %EBUSWP_W (command names,
#      ebusd messages, limits) and the path to the ebusd secret. The whitelist
#      below is an example for an Ochsner heat pump (OTE3 controller).
#
#  Version 2026-11-16
#
##############################################################################
package main;
use strict;
use warnings;
use POSIX qw(strftime);
use IO::Socket::INET;
use IO::Select;
use Blocking;

# Configuration for the FHEM to Heat Pump interface via ebusd.
# This module is the only write path from FHEM to the heat pump: it talks to ebusd via TCP port 8888.
# Authentication uses an ACL user with write permissions; the secret is stored in a file
# readable only by the FHEM user. Writing via MQTT is intentionally disabled.

my $EBUSWP_SECRET  = "/opt/fhem/.ebusd_secret";   # Path to the secret file for ACL user "fhem" (see /etc/ebusd/acl)
my $EBUSWP_PAUSE   = 10;                          # Minimum seconds between two bus accesses
my $EBUSWP_TAGESMAX = 20;                         # Max. write operations per key and day
my $EBUSWP_QUEUEMAX = 10;                         # Max. pending jobs (protection against loops)
my $EBUSWP_WAECHTER = 200;                        # Watchdog timeout in seconds: if no response, release the queue
                                                  #    (BlockingCall limit 150 s + buffer)

# Whitelist: Key (setList name) => ebusd message + validation rules.
# Only known, non-critical parameters with defined ranges/steps or allowed values are accepted;
# everything else is rejected.
#
# To add a new entry for your specific installation:
# 1. Determine the ebusd message name (e.g. with `ebusctl find -c <circuit>` or from the ebusd CSV configuration).
# 2. Add a new key to the %EBUSWP_W hash. The key is the name used in FHEM's setList.
# 3. Define the 'msg' field with the ebusd message path.
# 4. Define validation rules:
#    - 'enum': For discrete values (e.g., modes), provide an array of allowed strings.
#    - 'min'/'max': For numeric ranges.
#    - 'schritt': The step size (e.g., 0.5 or 1). The value must align with this grid.
#    - 'fmt': printf format string for the final value (e.g., '%.1f', '%d').
#    - 'uhr': Set to 1 if this is a time-sync command (special handling in child process).
# 5. Restart FHEM or reload the module.
my %EBUSWP_W = (
  HKR1_Betriebswahl => { msg => 'Betriebswahl.Heizkreis.03.050', enum => [qw(Standbybetrieb Automatik Handbetrieb_Heizen)] },
  HKR2_Betriebswahl => { msg => 'Betriebswahl.HKR2.03.050',      enum => [qw(Standbybetrieb Automatik Handbetrieb_Heizen)] },
  HKR1_Handsoll     => { msg => 'Solltemp.Handbetrieb.HKR1.07.009', min => 10, max => 34, schritt => 0.5, fmt => '%.1f' },
  HKR2_Handsoll     => { msg => 'Solltemp.Handbetrieb.HKR2.07.009', min => 10, max => 34, schritt => 0.5, fmt => '%.1f' },
  WW_Sollwert       => { msg => 'Warmwassertemp.SOLL.05.051',     min => 10, max => 60, schritt => 1,   fmt => '%d' },
  WW_Betriebswahl   => { msg => 'Betriebswahl.Warmwasser.05.050', enum => [qw(Keine_Ladung Automatik Normaltemperatur)] },
  WP_Uhrzeit_sync   => { msg => 'Waermepumpe.Uhrzeit.02.072',     uhr => 1 },
);

# Placeholder for module initialization.
# Purpose: Reserved for future initialization logic specific to this utility module.
# Parameters: $hash (device hash passed by FHEM core).
# Returns: None.
# Notes: Currently empty as the module relies on runtime state managed by other subs.
sub ebusWPUtils_Initialize($) { }

# Entry point called from the setList of an MQTT2_DEVICE.
# Returns undef to prevent any MQTT publication.
# Purpose: Validate input, apply safety checks (whitelist, lock, daily limit, queue), and enqueue the job.
# Parameters: $name (device name), $event (key and value separated by whitespace).
# Return: undef (always, to suppress MQTT output).
sub ebusWP_Set($$) {
  my ($name, $event) = @_;
  my $hash = $defs{$name};
  return undef if(!$hash);

  # Run watchdog to ensure queue is not blocked if a previous job hung.
  ebusWP_Waechter($hash);

  my ($key, $wert) = split(/\s+/, $event // "", 2);
  $key = "" if(!defined $key);
  $wert = "" if(!defined $wert);
  $wert =~ s/^\s+|\s+$//g;
  my $d = $EBUSWP_W{$key // ""};

  # Reject unknown keys not in the whitelist.
  return ebusWP_Status($hash, "abgewiesen: $key unbekannt") if(!$d);

  # Emergency stop: attribute "ebusSchreibsperre" blocks all writes.
  return ebusWP_Status($hash, "abgewiesen: Schreibsperre aktiv")
    if(AttrVal($name, "ebusSchreibsperre", 0) eq "1");

  my $senden;
  if($d->{enum}) {
    # Check against allowed enum values.
    return ebusWP_Status($hash, "abgewiesen: $key $wert nicht erlaubt")
      if(!grep { $_ eq $wert } @{$d->{enum}});
    $senden = $wert;
  } elsif($d->{uhr}) {
    # Time sync is handled specially in the child process; send marker "sync".
    $senden = "sync";                      # Validation and timing happen in the child process
  } else {
    # Numeric validation.
    # Replace comma with dot to handle locale-specific decimal input.
    $wert =~ s/,/./;

    # Strict numeric check: only ASCII digits [0-9] are allowed.
    # \d would accept Unicode digits which Perl might evaluate as 0, causing incorrect logic.
    return ebusWP_Status($hash, "abgewiesen: $key $wert keine Zahl")
      if($wert !~ /^[0-9]{1,2}(\.[0-9])?$/);

    # Range check.
    return ebusWP_Status($hash, "abgewiesen: $key $wert ausserhalb $d->{min}-$d->{max}")
      if($wert < $d->{min} || $wert > $d->{max});

    # Step/Grid check: value must align with the defined step size.
    my $n = $wert / $d->{schritt};
    return ebusWP_Status($hash, "abgewiesen: $key $wert nicht im Raster $d->{schritt}")
      if(abs($n - int($n + 0.5)) > 1e-6);

    # Format the value according to the required precision.
    $senden = sprintf($d->{fmt}, $wert);
  }

  # Optimization: If the current value (Reading) matches the target, skip the bus write.
  if(!$d->{uhr}) {
    my $ist = ReadingsVal($name, $d->{msg}, "");
    return ebusWP_Status($hash, "unveraendert: $key ist bereits $ist")
      if($ist ne "" && ($ist eq $senden || ($ist =~ /^-?[\d.]+$/ && $senden =~ /^-?[\d.]+$/ && $ist == $senden)));
  }

  # Daily limit check: Prevents excessive writes and protects the heat pump controller memory.
  my $heute = strftime("%Y-%m-%d", localtime);
  my $z = $hash->{helper}{ebusW}{zaehler}{$key} //= { tag => $heute, n => 0 };
  # Reset counter if the day has changed.
  ($z->{tag}, $z->{n}) = ($heute, 0) if($z->{tag} ne $heute);

  return ebusWP_Status($hash, "abgewiesen: Tageslimit $EBUSWP_TAGESMAX fuer $key erreicht")
    if($z->{n} >= $EBUSWP_TAGESMAX);

  # Increment counter for this key today.
  $z->{n}++;

  # Queue management.
  my $q = $hash->{helper}{ebusW}{queue} //= [];

  # If a job for the same key is already waiting, replace its value.
  # This ensures only the latest request is sent, reducing unnecessary bus traffic.
  my ($alt) = grep { $_->{key} eq $key } @{$q};
  if($alt) {                               # pending job for same key: keep only the newest value
    $z->{n}--;                             # replaced -> do not count twice
    my $vorher = $alt->{wert};
    $alt->{wert} = $senden;
    ebusWP_Status($hash, "ersetzt: $key $vorher -> $senden (" . scalar(@{$q}) . " in Warteschlange)");
  } else {
    # Enforce max queue size as a guard against runaway loops (e.g. an automation sending commands repeatedly).
    if(@{$q} >= $EBUSWP_QUEUEMAX) {
      $z->{n}--;
      Log3 $name, 1, "ebusWP Schreiben: Warteschlange voll ($EBUSWP_QUEUEMAX) - $key $senden verworfen";
      return ebusWP_Status($hash, "FEHLER: Warteschlange voll ($EBUSWP_QUEUEMAX) - $key $senden verworfen");
    }
    push @{$q}, { key => $key, msg => $d->{msg}, wert => $senden };
    ebusWP_Status($hash, "eingereiht: $key $senden (" . scalar(@{$q}) . " in Warteschlange)");
  }

  # Trigger the next job in the queue if no job is currently running.
  ebusWP_Next($hash);
  return undef;                            # do not publish anything via MQTT
}

# Helper to update a Reading and log the status.
# Always returns undef to prevent MQTT publication from setList context.
sub ebusWP_Status($$) {
  my ($hash, $txt) = @_;
  readingsSingleUpdate($hash, "Schreib_Status", $txt, 1);
  Log3 $hash->{NAME}, 3, "ebusWP Schreiben: $txt";
  return undef;
}

# Process the next job from the queue.
# Purpose: Enforce pause between bus accesses, start child process, and manage timeouts.
# Parameters: $hash (device hash).
# Return: None.
sub ebusWP_Next($) {
  my ($hash) = @_;

  # Check if a previous job is stuck (watchdog).
  ebusWP_Waechter($hash);

  my $h = $hash->{helper}{ebusW};

  # Do nothing if a job is already running or queue is empty.
  return if($h->{laeuft} || !$h->{queue} || !@{$h->{queue}});

  # Enforce minimum pause (10s) between two bus accesses.
  # The heat pump controller does not reliably process rapid write series.
  my $warten = ($h->{letzter} // 0) + $EBUSWP_PAUSE - gettimeofday();
  if($warten > 0) {
    RemoveInternalTimer($hash, "ebusWP_Next");
    InternalTimer(gettimeofday() + $warten, "ebusWP_Next", $hash, 0);
    return;
  }

  # Dequeue the next job.
  my $job = shift @{$h->{queue}};

  # Mark job as running and record start time for watchdog.
  $h->{laeuft} = 1;
  $h->{seit}   = gettimeofday();

  # Execute job in a child process using BlockingCall.
  # Timeout 150s: TCP connection and wait times would block FHEM otherwise.
  # A crash in the child process only terminates that process, keeping FHEM stable.
  $h->{pid} = BlockingCall("ebusWP_Kind", join("|", $hash->{NAME}, $job->{key}, $job->{msg}, $job->{wert}),
                           "ebusWP_Fertig", 150, "ebusWP_Abbruch", $hash);

  if(!$h->{pid}) {                         # child process not started: discard job, continue
    delete @{$h}{qw(laeuft pid seit)};
    $h->{letzter} = gettimeofday();
    readingsSingleUpdate($hash, "Schreib_Status", "FEHLER: Kindprozess nicht gestartet - $job->{key} $job->{wert}", 1);
    Log3 $hash->{NAME}, 1, "ebusWP Schreiben: FEHLER: Kindprozess nicht gestartet - $job->{key} $job->{wert}";
    # Schedule next job if queue is not empty.
    InternalTimer(gettimeofday() + $EBUSWP_PAUSE, "ebusWP_Next", $hash, 0) if(@{$h->{queue}});
    return;
  }

  # Watchdog timer: if neither 'done' nor 'aborted' callback arrives, free the queue.
  # This prevents the queue from being blocked indefinitely if the child process hangs silently.
  InternalTimer(gettimeofday() + $EBUSWP_WAECHTER + 1, "ebusWP_Next", $hash, 0);
}

# Watchdog logic.
# If a job runs longer than $EBUSWP_WAECHTER without response (e.g., malformed return value),
# reset the "running" flag to unblock the queue.
# If the timestamp is missing (e.g., after a reload during a job), count from now to ensure
# only one write operation runs at a time.
sub ebusWP_Waechter($) {
  my ($hash) = @_;
  my $h = $hash->{helper}{ebusW};
  return if(!$h || !$h->{laeuft});

  # Initialize timestamp if missing (e.g., after reload).
  $h->{seit} //= gettimeofday();           # e.g. after reload during running job: count from now

  # If timeout not reached, do nothing.
  return if(gettimeofday() - $h->{seit} < $EBUSWP_WAECHTER);

  # Kill the child process if it is still running.
  BlockingKill($h->{pid}) if(ref($h->{pid}));

  # Reset state variables.
  delete @{$h}{qw(laeuft pid seit)};
  $h->{letzter} = gettimeofday();

  # Update status reading and log the error.
  readingsSingleUpdate($hash, "Schreib_Status", "FEHLER: keine Rueckmeldung vom Kindprozess - Warteschlange freigegeben", 1);
  Log3 $hash->{NAME}, 1, "ebusWP Schreiben: FEHLER: keine Rueckmeldung vom Kindprozess - Warteschlange freigegeben";
}

# Helper to send a command via TCP socket and read the response.
# ebusd expects one command per line and ends responses with a blank line.
# Each command is sent in its own TCP packet because ebusd interprets multiple lines in one packet as a single command.
sub ebusWP_Befehl($$) {
  my ($sock, $cmd) = @_;
  print $sock "$cmd\n";
  my ($antwort, $sel) = ("", IO::Select->new($sock));

  # Wait for data or timeout (5s).
  while($sel->can_read(5)) {
    my $buf;
    last if(!sysread($sock, $buf, 4096));
    $antwort .= $buf;
    last if($antwort =~ /\n\n$/);          # ebusd ends every response with a blank line
  }

  # Trim trailing whitespace.
  $antwort =~ s/\s+$//;
  return $antwort eq "" ? "ERR: keine Antwort" : $antwort;
}

# Child process function: Connect to ebusd, authenticate, and execute the write/read cycle.
# Purpose: Handle the actual TCP communication and logic in a separate process.
# Parameters: $arg (pipe-separated string: name|key|msg|wert).
# Return: Pipe-separated string: name|key|wert|status|info|response.
sub ebusWP_Kind($) {
  my ($arg) = @_;
  my ($name, $key, $msg, $wert) = split(/\|/, $arg);

  # Helper to format error responses.
  my $fehler = sub { return join("|", $name, $key, $wert, "Fehler", $_[0], "") };

  # Step 1: Read the authentication secret from the file system.
  # The secret is kept in a separate file readable only by the FHEM user, so it never appears in the FHEM configuration.
  open(my $fh, '<', $EBUSWP_SECRET) or return $fehler->("Geheimnis nicht lesbar");
  my $secret = <$fh>; close($fh);
  chomp($secret);

  # Step 2: Establish TCP connection to ebusd on localhost port 8888.
  # Using 127.0.0.1 ensures local communication, minimizing network latency and security risk.
  my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => 8888, Proto => "tcp", Timeout => 5)
    or return $fehler->("ebusd nicht erreichbar");

  # Step 3: Special handling for time synchronization requests.
  if($wert eq "sync") {
    # Read current time from heat pump to check deviation.
    my $wp = ebusWP_Befehl($sock, "read -f -c ochsner $msg");
    return $fehler->("Uhrzeit nicht lesbar: $wp") if($wp !~ /^(\d\d):(\d\d)$/);

    my @t = localtime;
    # Calculate difference in minutes, normalized to -720..720 range.
    my $diff = ($1 * 60 + $2) - ($t[2] * 60 + $t[1]);
    $diff += 1440 if($diff < -720); $diff -= 1440 if($diff > 720);

    # Skip sync if deviation is small (<= 2 minutes) to avoid unnecessary bus traffic.
    return join("|", $name, $key, "", "unnoetig", "Abweichung $diff min", $wp) if(abs($diff) <= 2);

    # Do not sync during date change (23:44 to 00:15) to avoid setting incorrect date.
    my $hm = $t[2] * 60 + $t[1];
    return $fehler->("Sperrzeit 23:45-00:15") if($hm >= 23*60+44 || $hm <= 15);

    sleep(12);                             # Pause before writing (consistent with other writes)
    @t = localtime;

    # Wait until the start of the next minute to ensure a clean timestamp.
    sleep(60 - $t[0]) if($t[0] > 0);       # wait for minute start

    $wert = strftime("%H:%M", localtime);
  }

  # Step 4: Authenticate with ebusd using the previously read secret.
  my $auth = ebusWP_Befehl($sock, "auth fhem $secret");
  return $fehler->("auth: $auth") if($auth ne "done");

  # Step 5: Write the value to the heat pump via ebusd.
  my $w = ebusWP_Befehl($sock, "write -c ochsner $msg $wert");
  return $fehler->("write: $w") if($w ne "done");

  # Step 6: Wait 12s before reading back to allow the controller to process the write.
  # This delay is critical for reliability as the heat pump controller may take time to commit changes.
  sleep(12);                               # pause before reading back

  # Step 7: Read back the value to verify it was accepted.
  my $r = ebusWP_Befehl($sock, "read -f -c ochsner $msg");
  close($sock);

  # Step 8: Compare read-back value with sent value (numeric comparison for floats/ints).
  my $ok = ($r eq $wert || ($r =~ /^-?[\d.]+$/ && $wert =~ /^-?[\d.]+$/ && $r == $wert)) ? "ok" : "Abweichung";
  return join("|", $name, $key, $wert, $ok, "", $r);
}

# Callback for successful completion of the child process.
# Purpose: Update Readings, log the result, and trigger the next job in the queue.
# Parameters: $ret (pipe-separated result string from child process).
# Return: None.
sub ebusWP_Fertig($) {
  my ($ret) = @_;
  my ($name, $key, $wert, $ergebnis, $info, $rueck) = split(/\|/, $ret // "", 6);
  my $hash = $defs{$name // ""};
  return if(!$hash);

  my $h = $hash->{helper}{ebusW};

  # Clear "running" state.
  delete @{$h}{qw(laeuft pid seit)};
  $h->{letzter} = gettimeofday();

  # Ensure all variables are defined.
  $_ //= "" foreach ($key, $wert, $ergebnis, $info, $rueck);

  # Build status text.
  my $txt = $ergebnis eq "ok"       ? "ok: $key = $wert (rueckgelesen $rueck)"
          : $ergebnis eq "unnoetig" ? "unveraendert: $key $info (WP $rueck)"
          : "FEHLER: $key $wert - " . ($info || "Ruecklesen $rueck");

  # Update Readings.
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash, "Schreib_Status", $txt);
  readingsBulkUpdate($hash, "Schreib_Letzter", strftime("%Y-%m-%d %H:%M:%S", localtime) . " $key $wert $ergebnis")
    if($ergebnis ne "unnoetig");
  readingsEndUpdate($hash, 1);

  # Log the result.
  Log3 $name, ($ergebnis eq "ok" || $ergebnis eq "unnoetig") ? 3 : 1, "ebusWP Schreiben: $txt";

  # Process next job in queue.
  ebusWP_Next($hash);
}

# Callback for aborted/timed-out child process.
# Purpose: Clean up state, log error, and continue with next job.
# Parameters: $hash (device hash).
# Return: None.
sub ebusWP_Abbruch($) {
  my ($hash) = @_;
  my $h = $hash->{helper}{ebusW};

  # Clear "running" state.
  delete @{$h}{qw(laeuft pid seit)};
  $h->{letzter} = gettimeofday();

  # Update status and log error.
  ebusWP_Status($hash, "FEHLER: Zeitueberschreitung beim Schreiben");

  # Process next job in queue.
  ebusWP_Next($hash);
}

1;

=pod
=item helper
=item summary    only write path FHEM -> heat pump via ebusd (whitelist, queue, read-back)
=item summary_DE einziger Schreibweg FHEM -> Waermepumpe ueber ebusd (Whitelist, Warteschlange, Ruecklesen)
=begin html

<a id="ebusWPUtils"></a>
<h3>ebusWPUtils</h3>
<ul>
  Helper module (no device of its own) that provides the <b>only write path</b> from FHEM to a heat pump via ebusd.
  Reading values works without this module (ebusd publishes them via MQTT); writing goes through
  <code>ebusWP_Set</code>, which validates every command, queues it and executes it in a child process that talks
  to ebusd via TCP with authentication. Writing via MQTT (<code>.../set</code> topics) is meant to be blocked in ebusd.<br><br>

  <b>Prerequisites</b>
  <ul>
    <li>ebusd started with <code>--aclfile</code> and <code>--localhost</code>; an ACL user (e.g. <code>fhem</code>) with
      access level <i>write</i>; the MQTT user has no write access.</li>
    <li>The secret of that ACL user in a file readable only by the FHEM user
      (default <code>/opt/fhem/.ebusd_secret</code>, only the secret string).</li>
    <li>An FHEM device with the ebusd readings (e.g. an MQTT2_DEVICE <code>ebusWP</code>), whose readings are used for
      the "unchanged" check.</li>
  </ul><br>

  <b>Integration</b>
  <ul>
    Every write command is an entry of the <i>setList</i> of the ebusd device that calls <code>ebusWP_Set</code>
    (the function returns nothing, so nothing is published via MQTT):
<pre>
attr ebusWP setList HKR1_Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen {ebusWP_Set($NAME,$EVENT)}
HKR1_Handsoll:slider,10,0.5,34 {ebusWP_Set($NAME,$EVENT)}
WW_Sollwert:slider,10,1,60 {ebusWP_Set($NAME,$EVENT)}
WP_Uhrzeit_sync:noArg {ebusWP_Set($NAME,$EVENT)}
</pre>
    Usage: <code>set ebusWP HKR1_Handsoll 25.5</code>. Only commands listed in the whitelist <code>%EBUSWP_W</code> in the
    source code are accepted (each with its ebusd message and its allowed values, range and step); everything else is rejected.
  </ul><br>

  <b>Attribute (on the ebusd device)</b>
  <ul>
    <li><b>ebusSchreibsperre</b> &ndash; emergency stop: <code>1</code> rejects every write command
      (declare first with <code>attr ebusWP userattr ebusSchreibsperre:0,1</code>).</li>
  </ul><br>

  <b>Readings (on the ebusd device)</b>
  <ul>
    <li><b>Schreib_Status</b> &ndash; result of the last action:
      <i>eingereiht</i> (queued), <i>ersetzt</i> (value of a waiting job replaced), <i>unveraendert</i> (value already set,
      no bus access), <i>abgewiesen</i> (rejected: unknown, not a number, out of range, not in step, not allowed, write lock,
      daily limit), <i>ok</i> (written and read back), <i>FEHLER</i> (error: ebusd not reachable, authentication, read-back
      mismatch, timeout, queue full, child process not started, no response).</li>
    <li><b>Schreib_Letzter</b> &ndash; time, command, value and result of the last write, e.g.
      <code>2026-11-16 10:09:30 HKR2_Handsoll 20.0 ok</code>.</li>
  </ul><br>

  <b>Safeguards</b>
  <ul>
    <li>Whitelist with range, step and allowed values per command; numbers only with ASCII digits, comma accepted as decimal separator.</li>
    <li>Same value as the current reading &rarr; no bus access.</li>
    <li>Queue: at least 10 s between two bus accesses (the controller does not reliably handle fast write series);
      a waiting job for the same command is replaced; at most 10 waiting jobs.</li>
    <li>Daily limit of 20 writes per command (protection against loops and unnecessary write cycles in the controller).</li>
    <li>Execution in a child process (BlockingCall, 150 s timeout): FHEM never blocks.</li>
    <li>Read-back 12 s after writing and comparison with the sent value.</li>
    <li>Watchdog: if the child process does not start or never reports back, the queue is released after 200 s.</li>
    <li>Time synchronisation (<code>WP_Uhrzeit_sync</code>): only if the deviation exceeds 2 minutes, at the start of a minute,
      never between 23:44 and 00:15.</li>
  </ul><br>

  <b>Adapting to another installation</b>
  <ul>
    Edit the whitelist <code>%EBUSWP_W</code> in the source: key = setList command name, <code>msg</code> = ebusd message name
    (see <code>ebusctl find</code> or the ebusd CSV configuration), then either <code>enum</code> (allowed values) or
    <code>min</code>/<code>max</code>/<code>schritt</code>/<code>fmt</code> (range, step, output format), or <code>uhr =&gt; 1</code>
    for time synchronisation. Adjust the path of the secret file if needed, then <code>reload 99_ebusWPUtils.pm</code>.
    The whitelist in this file is an example for an Ochsner heat pump (OTE3 controller).
  </ul>
</ul>

=end html

=begin html_DE

<a id="ebusWPUtils"></a>
<h3>ebusWPUtils</h3>
<ul>
  Hilfsmodul (ohne eigenes Device), das den <b>einzigen Schreibweg</b> von FHEM zu einer W&auml;rmepumpe &uuml;ber ebusd bereitstellt.
  Lesen funktioniert ohne dieses Modul (ebusd ver&ouml;ffentlicht die Werte per MQTT); geschrieben wird &uuml;ber
  <code>ebusWP_Set</code>: Die Funktion pr&uuml;ft jeden Befehl, reiht ihn in eine Warteschlange ein und f&uuml;hrt ihn in einem
  Kindprozess aus, der per TCP mit Anmeldung mit ebusd spricht. Schreiben per MQTT (<code>.../set</code>-Topics) soll in ebusd gesperrt sein.<br><br>

  <b>Voraussetzungen</b>
  <ul>
    <li>ebusd l&auml;uft mit <code>--aclfile</code> und <code>--localhost</code>; ein ACL-Benutzer (z. B. <code>fhem</code>) mit
      Zugriffsstufe <i>write</i>; der MQTT-Benutzer hat keine Schreibrechte.</li>
    <li>Das Geheimnis dieses ACL-Benutzers liegt in einer Datei, die nur der FHEM-Benutzer lesen darf
      (Standard <code>/opt/fhem/.ebusd_secret</code>, nur die Zeichenkette).</li>
    <li>Ein FHEM-Device mit den ebusd-Readings (z. B. ein MQTT2_DEVICE <code>ebusWP</code>); dessen Readings dienen der
      Pr&uuml;fung &bdquo;unver&auml;ndert&ldquo;.</li>
  </ul><br>

  <b>Einbindung</b>
  <ul>
    Jeder Schreibbefehl ist ein Eintrag in der <i>setList</i> des ebusd-Devices, der <code>ebusWP_Set</code> aufruft
    (die Funktion gibt nichts zur&uuml;ck, daher wird nichts per MQTT ver&ouml;ffentlicht):
<pre>
attr ebusWP setList HKR1_Betriebswahl:Standbybetrieb,Automatik,Handbetrieb_Heizen {ebusWP_Set($NAME,$EVENT)}
HKR1_Handsoll:slider,10,0.5,34 {ebusWP_Set($NAME,$EVENT)}
WW_Sollwert:slider,10,1,60 {ebusWP_Set($NAME,$EVENT)}
WP_Uhrzeit_sync:noArg {ebusWP_Set($NAME,$EVENT)}
</pre>
    Aufruf: <code>set ebusWP HKR1_Handsoll 25.5</code>. Angenommen werden nur Befehle aus der Whitelist <code>%EBUSWP_W</code> im
    Quelltext (je mit ebusd-Nachricht und erlaubten Werten, Bereich und Raster); alles andere wird abgewiesen.
  </ul><br>

  <b>Attribut (am ebusd-Device)</b>
  <ul>
    <li><b>ebusSchreibsperre</b> &ndash; Not-Aus: <code>1</code> weist jeden Schreibbefehl ab
      (vorher anmelden mit <code>attr ebusWP userattr ebusSchreibsperre:0,1</code>).</li>
  </ul><br>

  <b>Readings (am ebusd-Device)</b>
  <ul>
    <li><b>Schreib_Status</b> &ndash; Ergebnis der letzten Aktion:
      <i>eingereiht</i>, <i>ersetzt</i> (Wert eines wartenden Auftrags ersetzt), <i>unveraendert</i> (Wert bereits gesetzt,
      kein Buszugriff), <i>abgewiesen</i> (unbekannt, keine Zahl, au&szlig;erhalb, nicht im Raster, nicht erlaubt, Schreibsperre,
      Tageslimit), <i>ok</i> (geschrieben und r&uuml;ckgelesen), <i>FEHLER</i> (ebusd nicht erreichbar, Anmeldung,
      R&uuml;cklesen abweichend, Zeit&uuml;berschreitung, Warteschlange voll, Kindprozess nicht gestartet, keine R&uuml;ckmeldung).</li>
    <li><b>Schreib_Letzter</b> &ndash; Zeit, Befehl, Wert und Ergebnis des letzten Schreibvorgangs, z. B.
      <code>2026-11-16 10:09:30 HKR2_Handsoll 20.0 ok</code>.</li>
  </ul><br>

  <b>Schutzma&szlig;nahmen</b>
  <ul>
    <li>Whitelist mit Bereich, Raster und erlaubten Werten je Befehl; Zahlen nur mit ASCII-Ziffern, Komma als Dezimaltrenner erlaubt.</li>
    <li>Gleicher Wert wie das aktuelle Reading &rarr; kein Buszugriff.</li>
    <li>Warteschlange: mindestens 10 s zwischen zwei Buszugriffen (der Regler verarbeitet schnelle Schreibserien nicht zuverl&auml;ssig);
      ein wartender Auftrag f&uuml;r denselben Befehl wird ersetzt; h&ouml;chstens 10 wartende Auftr&auml;ge.</li>
    <li>Tageslimit 20 Schreibvorg&auml;nge je Befehl (Schutz vor Schleifen und unn&ouml;tigen Schreibzyklen im Regler).</li>
    <li>Ausf&uuml;hrung im Kindprozess (BlockingCall, Zeitlimit 150 s): FHEM blockiert nie.</li>
    <li>R&uuml;cklesen 12 s nach dem Schreiben und Vergleich mit dem gesendeten Wert.</li>
    <li>W&auml;chter: Startet der Kindprozess nicht oder meldet er sich nie zur&uuml;ck, wird die Warteschlange nach 200 s freigegeben.</li>
    <li>Uhrzeit-Abgleich (<code>WP_Uhrzeit_sync</code>): nur bei mehr als 2 Minuten Abweichung, zum Minutenbeginn,
      nie zwischen 23:44 und 00:15.</li>
  </ul><br>

  <b>Anpassung an eine andere Anlage</b>
  <ul>
    Whitelist <code>%EBUSWP_W</code> im Quelltext anpassen: Schl&uuml;ssel = Befehlsname in der setList, <code>msg</code> = ebusd-Nachrichtenname
    (siehe <code>ebusctl find</code> oder die ebusd-CSV-Konfiguration), dazu entweder <code>enum</code> (erlaubte Werte) oder
    <code>min</code>/<code>max</code>/<code>schritt</code>/<code>fmt</code> (Bereich, Raster, Ausgabeformat) oder <code>uhr =&gt; 1</code>
    f&uuml;r den Uhrzeit-Abgleich. Bei Bedarf den Pfad der Geheimnis-Datei anpassen, dann <code>reload 99_ebusWPUtils.pm</code>.
    Die Whitelist in dieser Datei ist ein Beispiel f&uuml;r eine Ochsner-W&auml;rmepumpe (Regler OTE3).
  </ul>
</ul>

=end html_DE

=cut
