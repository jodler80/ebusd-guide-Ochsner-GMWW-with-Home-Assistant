# FHEM modules for ebusd

FHEM section of this guide. Step-by-step integration (MQTT2_DEVICE, ACL, tests): [English](../../docs/fhem_integration_example.md) / [Deutsch](../../docs/fhem_integration_example_de.md).

Two FHEM modules for heat pumps (and other heating devices) connected through
[ebusd](https://github.com/john30/ebusd):

| File | Purpose |
|---|---|
| `98_EBUSFUNC.pm` | **Function block** on top of an existing ebusd device (e.g. an MQTT2_DEVICE with ebusd readings): mirrors selected readings (`readingMap`), offers checked operating commands (`setMap`) and temporary **override functions** such as economy mode or PV self-consumption priority (`overrideList`) that remember, override and restore controller settings. |
| `99_ebusWPUtils.pm` | **The only write path** from FHEM to the heat pump: whitelist with range/step/allowed values, queue with at least 10 s between bus accesses, daily limit, emergency stop, execution in a child process (BlockingCall) via ebusd TCP with ACL authentication, read-back check, watchdog. |

EBUSFUNC itself never talks to the bus: it only issues `set <ebusDevice> <command> <value>`.
Whether and how that command is written is decided by the ebusd device, e.g. through `ebusWP_Set`.

The full documentation (English and German) is the commandref inside the modules:
`help EBUSFUNC` and `help ebusWPUtils` in FHEMWEB.

## Installation

1. Copy both `.pm` files to the `FHEM/` directory of your installation (owner = FHEM user), then
   `reload 98_EBUSFUNC.pm` and `reload 99_ebusWPUtils.pm` (or restart FHEM).
2. ebusd: start with `--aclfile` and `--localhost`, create an ACL user with access level `write`
   for FHEM, keep the MQTT user read-only. Put the secret into `/opt/fhem/.ebusd_secret`
   (readable only by the FHEM user).
3. **Adapt the whitelist `%EBUSWP_W`** in `99_ebusWPUtils.pm` to your device. The shipped list is an
   example for an Ochsner heat pump with OTE3 controller (see [ochsner_tem_protocol.md](../../docs/ochsner_tem_protocol.md)) and must not be used unchecked on other devices.
4. Add the write commands to the `setList` of your ebusd device, see `examples/ebusd_device_setList.cfg`.
5. Define function blocks, see `examples/heating_circuit_and_hot_water.cfg`
   (a heating circuit with economy/priority override and a hot water block, as running in a real installation).

## Tests

The tests run without FHEM and without a bus (FHEM functions and BlockingCall are stubbed):

```
cd test
perl -I . test_EBUSFUNC.pl            # function tests
perl -I . test_EBUSFUNC_robust.pl     # fuzz / robustness
perl -I . test_ebusWPUtils.pl         # write path incl. queue, watchdog
perl -I . test_ebusWPUtils_robust.pl  # fuzz: no invalid value ever reaches the bus
```

`code_unveraendert.sh old.pm new.pm` proves via `B::Deparse` that a change touched only comments/POD.

## Safety

Writing to a heating controller can affect comfort, efficiency and component lifetime.
Both modules restrict what can be written, but you are responsible for the whitelist, the limits
and the automations that use them. Use at your own risk.

## License

The FHEM modules and tests in this directory: GPL v2 or later, like FHEM itself. See [`LICENSE`](./LICENSE).

---

## Deutsch (Kurzfassung)

Zwei FHEM-Module für Wärmepumpen über ebusd:

- **98_EBUSFUNC.pm**: Funktionsblock über einem vorhandenen ebusd-Device. Es spiegelt Readings (`readingMap`),
  bietet geprüfte Bedienbefehle (`setMap`) und Sonderfunktionen wie Spar- oder Eigenverbrauchsbetrieb
  (`overrideList`), die Einstellungen merken, überschreiben und wieder zurückstellen.
- **99_ebusWPUtils.pm**: einziger Schreibweg FHEM → Wärmepumpe. Er bietet Whitelist, Warteschlange (≥ 10 s Abstand),
  Tageslimit, Not-Aus, Kindprozess, Rücklesen und Wächter.

Ausführliche Hilfe auf Deutsch: `help EBUSFUNC` bzw. `help ebusWPUtils` (FHEM-Sprache `de`).
Installation, Tests und Hinweise wie oben. Die Whitelist ist ein Beispiel für eine Ochsner-WP mit OTE3-Regler
und muss an die eigene Anlage angepasst werden.
