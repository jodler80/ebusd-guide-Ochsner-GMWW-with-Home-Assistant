# Ochsner OTE3 / TEM Protocol: Decoding and Verified Parameter List

This page describes how the Ochsner heat pump (OTE3 controller) responds via eBUS with the TEM protocol,
how to decode the responses yourself, and which data points have been verified. Basis: an Ochsner GMWW 10
with OTE3 software version 5.98, ebusd 26.1, and an eBUS Adapter Shield C6 (Stick version). All values were compared with the heat pump's control panel in October 2026.

## 1. Structure of a TEM Response

Query (Read): `QQ ZZ 06 21 04 <Bus ID 4 bytes>`, Response 10 bytes:

| Byte | Meaning |
|---|---|
| 0–1 | **Parameter number** (Little Endian): `0x8000 + Group·128 + Number`. For setting values, bit 14 is also set (Group ≥ 128 → `& 0x7f`). Example `33 81` → 0x8133 → **02-051**. |
| 2 | **Type** (scaling, see below) |
| 3 | **Unit** |
| 4–7 | Maximum / Minimum (for Type `1d` part of the number format) |
| 8–9 | Value |

Response `ff 9f 00 …` means: Parameter does not exist at this address.

With bytes 0–1, **every message can be checked against the system**: The heat pump itself indicates which
OTE3 parameter is behind a bus ID. This is how all messages of this configuration were checked.

### Types (Byte 2)

| Type | Meaning | Examples |
|---|---|---|
| `0d` | Value with **one decimal place** (divisor 10) | Temperatures, volume flows, kWh counter |
| `04` | Integer | MWh, date, time |
| `00` / `01` | Integer unsigned / signed 1 byte | Status, standard outdoor temperature |
| `02` | On/Off | Pumps |
| `09` | Selection (Enum) | Operating mode |
| `4d` / `8d` | Setting value, divisor 10 | Offset, heating limit, setpoint temperatures |
| `c1` | Command | Mixer heating circuit 2 |
| `1d` | Counter in HCD format | Switching cycles, operating hours |

Exception: 03-013 (Supply temperature at standard outdoor temperature) has type `00`, but the raw value must be divided by 2
(61 → 30.5 °C, confirmed on the control panel).

### Units (Byte 3)

`02` °C · `08` % · `12` kWh · `34` l/min · `3c` MWh · `28` Date · `2a` Time · `10` Power (kW)

## 2. Counter with Type 1d (HCD)

Switching cycles (02-080) and operating hours (02-081) are **not** in bytes 8–9, but in **bytes 6–9 as HCD**:
each byte is a two-digit decimal number (0–99), with the least significant byte coming first.

| | Byte 6–9 | as numbers | Result | Displayed value |
|---|---|---|---|---|
| Switching cycles | `0d 20 03 00` | 13 · 32 · 3 · 0 | 3·10⁴ + 32·10² + 13 = 33213 | 33213 |
| Operating hours | `13 24 50 01` | 19 · 36 · 80 · 1 | 1803619 → 18036.19 h | 18036 |

In ebusd: Ignore the header, which is only 6 bytes (`IGN:6`, template `param6`), then `HCD:4` (operating hours with a divisor of 100).
Previous configurations with `U3N` or `UIN` provided incorrect values (3 and 336, respectively).

## 3. Bus ID Scheme and Modules

Normal parameters: **`[Group][0x80 + Number] 00 [Module]`**, e.g., 02-080 to Module 42 → `02d00042`,
03-021 to Module 4a → `0395004a`.

| Module | Content |
|---|---|
| `02` | Heat pump: Counters, volume flows, energy, source pump |
| `08` / `48` | Heating circuit 1: Live values / settings |
| `0a` / `4a` | Heating circuit 2: Live values / settings |
| `0e` / `4e` | Domestic hot water: Live values / settings |
| `10` / `50` | Heat distributor (buffer): Live values / settings |
| `40` | System / System (domestic hot water actual value, date, time) |
| `42` | Heat pump: Measured values and settings |

In addition, there are **alias addresses** that provide the same parameters:

| Alias | Parameter |
|---|---|
| `7d85…7d8c 0002` | 02-080, 02-081, 21-002, 21-090, 23-001, 23-010, 23-006, 23-013 |
| `7a80…7a86 0010` | 00-015, 00-017, 00-096, 01-096, 02-040, 02-041, 02-054 |
| `6980 / 6981 0002` | 09-007, 15-006 |
| `6380…6387 00yy` (yy = 08 Heating circuit 1, 0a Heating circuit 2) | continuous list: 03-000, 03-001, 03-002, 03-012, 03-013, 03-021, 03-051, 03-053 |
| `77 8x 00yy` | Live values heating circuit: 7780 = 02-051, 7782 = 02-020, 7783 = 01-001, 7784 = 00-002, 7785 = 01-002 |

The `638x` list is **not a double assignment** (previous assumption "expert conflict"), but a numbered list.

## 4. Check Yourself

1. Start `ebusd` **temporarily** with `--enablehex` (remove it afterward).
2. Raw query: `ebusctl hex 15062104<Bus-ID>`, e.g., `ebusctl hex 1506210402d00042`.
3. **At least a 1.5-second pause** between queries, otherwise the heat pump will no longer respond. Also, operating the display occupies the bus (the control panel itself is an eBUS master).
4. Convert byte 0–1 of the response into the parameter number and compare it with the name; compare the value with the display.
5. Alternative without `--enablehex`: `ebusctl grab`, then after some polls, `ebusctl grab result all`.

## 5. Corrections Compared to Previous Configurations

| Data Point | Problem | Correction |
|---|---|---|
| Heating energy / Hot water energy kWh | Raw value is in 0.1 kWh (Display 164.1 – eBUS 1641) | Template `kwh` with divisor 10. kWh is the remainder below 1 MWh: Total = MWh + kWh/1000 |
| Switching cycles, operating hours | Incorrect format (U3N/UIN) | `param6` + `HCD:4` (Hours divisor 100) |
| `Warmwasserenergie.kWh.23.066` | Parameter is named 23-006 (Display and Header) | Renamed to `Warmwasserenergie.kWh.23.006` — **new name, possibly new entity** |
| Operating mode heating circuit 03-050 | Enum was shifted | 0 = Standby mode, 1 = Automatic, 4 = Normal operation, 5 = Energy-saving mode, 7 = Manual heating mode (checked on the display) |
| Hot water status 02-052 | Value 8 was missing | `8 = Bedarfsladung_Hysterese` (derived from measured data, see below) |
| Heating circuit status 02-051 | Value 23 was missing | `23 = Heizbetrieb_aktiv` |
| Mixer heating circuit 2 (01-021) | No position value | Command signal (idle 0, short pulse 156) |
| Date 02-070 | ebusd type `DAY` shows +1 day | Ochsner counts from 1, not from 0; display shows correct value. Do not write date via ebusd |
| new | | Operating mode heating circuit 2, setpoint system 01-096, heating output 02-040 / 02-041 (−100.0 = not available), pump heating circuit 2 |

**Changed message names (this creates new entities in Home Assistant):**

| Previously | New | Reason |
|---|---|---|
| `Status.Heizkreispumpe.01.020` | `Status.HKR1.Pumpe.01.020` | Pump of heating circuit 1 (module 48) |
| `Mischer.Heizkreispumpe.01.021` | `Mischer.HKR2.01.021` | Mixer of heating circuit 2 (module 0a) |
| `Warmwasserenergie.kWh.23.066` | `Warmwasserenergie.kWh.23.006` | Parameter number according to display and header |

## 6. Observed System Behavior

- **Domestic Hot Water Recharge (Status 8):** If the domestic hot water temperature drops to approximately the setpoint minus 5 K (at a setpoint of 43 °C ≈ 38 °C),
  the heat pump charges up to approximately the setpoint (≈ 44 °C).
- **External Priority Contact (Utility/Release Input):** The relay input of the heat pump is activated **when the contact is open** (inverted logic). Then, the heat pump immediately sets the **active domestic hot water setpoint (01-004) from 43 to 60 °C**; if the domestic hot water is below ≈ 55 °C, a charge to ≈ 60 °C is started (Status 1 `Normal_Ladebetrieb`). When switched back, the setpoint returns to 43 °C. The setpoints of the
  heating circuits do not change in the process. `Warmwassertemp.SOLL.aktuell.01.004 = 60` is therefore an indicator of
  active priority.
- **Standby:** According to the operator, if both heating circuits are in standby mode, no domestic hot water is heated, even with priority enabled (cannot be verified from the data). The "Switched Off" status (no heating demand) does not prevent the
  charge.
- **Electric Heating Element in the Tank:** If it is switched on externally, the domestic hot water temperature increases without the
  heat pump reporting a charging status.
- **Heat Pump Clock:** No time synchronization; drifts (here ≈ 7 minutes ahead).

## 7. eBUS Adapter Shield C6 to USB

- Host mode "USB serial", protocol **Enhanced**; ebusd: `--device=ens:/dev/serial/by-id/usb-Espressif_…-if00`
  (use the `by-id` path instead of `ttyACM0`), no `--latency` required.
- **Restart the adapter and then ebusd after each change of host mode, protocol, or WLAN.** Otherwise, the
  setting will only be partially applied, and each individual query will end with `arbitration won in invalid state`.
- **Keep the adapter's WLAN enabled:** without WLAN, the adapter responds 50-100 ms slower via USB, and individual
  queries will then consistently fail. `--latency` does not help.
- "Plain protocol" is not suitable via USB (ebusd would have to arbitrate itself).
- Use a USB **data** cable; a charging cable only supplies power to the adapter.
- Protect the adapter's web interface with a username and password; in USB mode, the TCP port 9999 is closed.

## 8. Example Integration (FHEM) — Not part of the eBUS decoding

> This section describes only how the values can be further used in home automation. It is not necessary for the eBUS configuration itself.

- `ebusd` publishes the values via MQTT under `ebusd/ochsner/<message>`; in FHEM, a `MQTT2_DEVICE` takes them over (set a fixed MQTT client ID in `ebusd`: `--mqttclientid=…`).
- Text enums (e.g., operating mode selection) are translated back into code for databases that only store numbers using `userReadings`. Note that: FHEM checks the trigger against the entire event `Reading: Value`, so use `Betriebswahl\.Heizkreis\.03\.050:.*` as the trigger.

## 9. Verified Parameter List

"verified" = parameter number in the response header is confirmed, and the value is compared with the display. "(not polled)" = bus ID is known, but not queried in `gmww11plus.csv`.

| Code | Area | Description | Bus-ID | ebusd message | Unit | Status |
|---|---|---|---|---|---|---|
| 00-000 | WP | Current outside temperature | `00800042` | `Aktuelle.Aussentemperatur.00.000` | °C | verified |
| 00-007 | WP | Supply temperature WP (TWV) | `00870042` | `Vorlauftemp.Waermepumpe.TWV.00.007` | °C | verified |
| 00-008 | WP | Return temperature WP (TWR) | `00880042` | `Ruecklauftemp.Waermepumpe.TWR.00.008` | °C | verified |
| 00-070 | WP | Source outlet TQA | `00c60042` | `Austrittstemp.Waermequelle.TQA.00.070` | °C | verified |
| 00-071 | WP | Source inlet TQE | `00c70042` | `Eintrittstemp.Waermequelle.TQE.00.071` | °C | verified |
| 01-022 | WP | Heat source pump control (%) - no on/off | `01960042` | `Status.Waermeerzeugerpumpe.01.022` | % | verified |
| 01-076 | WP | Desired compressor speed | `01cc0042` | `Drehzahl.Waermeerzeugerpumpe.01.076` | % | verified |
| 01-077 | WP | Heat source pump (Alias 7b82) | `7b820002` | `Drehzahl.Waermequellenpumpe.01.077` | % | verified |
| 02-020 | WP | Average outside temperature (HKR1) | `77820008` | `Aussentemperatur.Mittelwert.02.020` | °C | verified |
| 02-040 | System | Heating power heating (Display -100.0 = not available) | `7a840010` | `Heizleistung.Heizen.02.040` | kW | verified |
| 02-041 | System | Heating power hot water (Display -100.0 = not available) | `7a850010` | `Heizleistung.Warmwasser.02.041` | kW | verified |
| 02-053 | WP | Status heat pump | `02b50042` | `Status.Waermepumpe.02.053` |  | verified |
| 02-054 | System | Status heat manager (Alias 7a86) | `7a860010` | (not polled) |  | verified |
| 09-007 | WP | Heat generator type (Alias 6980) | `69800002` | (not polled) |  | verified |
| 09-075 | WP | Operating mode heat generator | `09cb0042` | `Betriebswahl.Waermepumpe.09.075` |  | verified |
| 15-006 | WP | Application type heat pump (Alias 69810002; 69820002 does not exist) | `0f860042` | (not polled) |  | verified |
| 02-080 | WP | Compressor switching cycles (Type 1d, HCD: 4) | `7d850002` | `Waermepumpe.Schaltzyklen.02.080` |  | verified |
| 02-081 | WP | Compressor operating hours (Type 1d, HCD: 4, 100) | `7d860002` | `Waermepumpe.Betriebsstunden.02.081` | h | verified |
| 02-070 | WP | Date WP (Type DAY: Display +1 day, Ochsner starts at 1) | `02c60040` | `Waermepumpe.Datum.02.070` |  | verified |
| 02-072 | WP | Time WP (minutes since midnight; WP clock ~7 min ahead) | `02c80040` | `Waermepumpe.Uhrzeit.02.072` |  | verified |
| 00-015 | System | Supply temperature buffer top (TPO) | `7a800010` | `Vorlauftemp.Puffersp.TPO.00.015` | °C | verified |
| 00-017 | System | Supply temperature buffer middle (TPM) | `7a810010` | `Vorlauftemp.Puffersp.TPM.00.017` | °C | verified |
| 00-096 | System | System supply temperature (Module 10) | `7a820010` | `Vorlauftemp.Anlage.00.096` | °C | verified |
| 00-096 | System | System supply via module 40 = duplicate (Ø 0.19 K) - query removed 2026-10-23 | `00e00040` | (entfernt: Diagnose.Temp.00.224) | °C | Duplicate |
| 01-096 | System | Heating distributor setpoint system (Module 50; Alias 7a830010) | `01e00050` | `Sollwert.Anlage.01.096` | °C | verified |
| 06-015 | WM | Operating mode heating distributor (Module 50; 668b0010 does not exist) | `068f0050` | (not polled) |  | verified |
| 06-076 | WM | Application type heating distributor (Module 50; 66940010 does not exist) | `06cc0050` | (not polled) |  | verified |
| 00-004 | DHW | Current hot water temperature | `00840040` | `Warmwassertemp.aktuell.00.004` | °C | verified |
| 01-004 | DHW | Current hot water setpoint | `7982000e` | `Warmwassertemp.SOLL.aktuell.01.004` | °C | verified |
| 01-066 | DHW | Hot water preparation with heat pump active | `01c2004e` | `Warmwasserbereitung.mit.Waermepumpe.01.066` |  | verified |
| 02-052 | DHW | Status hot water control (8 = demand-based hysteresis, derived) | `7980000e` | `Status.Warmwasser.02.052` |  | verified |
| 05-050 | DHW | Operating mode hot water | `05b2004e` | `Betriebswahl.Warmwasser.05.050` |  | verified |
| 05-051 | DHW | Hot water setpoint day | `05b3004e` | `Warmwassertemp.SOLL.05.051` | °C | verified |
| 05-076 | DHW | Application type DHW preparation (6582000e delivers 05-086) | `05cc004e` | (not polled) |  | verified |
| 05-086 | DHW | Low hot water temperature | `05d6004e` | `Warmwassertemp.Spar.05.086` | °C | verified |
| 21-002 | Energy | Volume flow rate heating side | `7d870002` | `Volumenstrom.Waermenutzung.21.002` | l/min | verified |
| 21-090 | Energy | Volume flow rate heat source | `7d880002` | `Volumenstrom.Waermequelle.21.090` | l/min | verified |
| 23-001 | Energy | Heating energy kWh share (remainder below 1 MWh, 0.1 kWh) | `7d890002` | `Heizenergie.kWh.23.001` | kWh | verified |
| 23-010 | Energy | Heating energy MWh share | `7d8a0002` | `Heizenergie.MWh.23.010` | MWh | verified |
| 23-006 | Energy | Hot water energy kWh share (remainder below 1 MWh, 0.1 kWh) | `7d8b0002` | `Warmwasserenergie.kWh.23.006` | kWh | verified |
| 23-013 | Energy | Hot water energy MWh share | `7d8c0002` | `Warmwasserenergie.MWh.23.013` | MWh | verified |
| 00-002 | HKR1 | Supply temperature HKR1 actual (= TPO, no separate sensor detectable) | `77840008` | `Istwert.Heizkreis.Vorlauftemp.00.002` | °C | verified |
| 01-001 | HKR1 | Room setpoint HKR1 | `77830008` | `Aktueller.Raumsollwert.01.001` | °C | verified |
| 01-002 | HKR1 | Supply temperature HKR1 setpoint | `77850008` | `Sollwert.Heizkreis.Vorlauftemp.01.002` | °C | verified |
| 01-020 | HKR1 | Heating circuit pump HKR1 (ON/OFF) | `01940048` | `Status.HKR1.Pumpe.01.020` |  | verified |
| 02-051 | HKR1 | Status heating circuit control HKR1 | `77800008` | `Status.Heizkreis.02.051` |  | verified |
| 03-000 | HKR1 | Setting value 03-000 (description open; Alias 63800008) | `03800048` | (not polled) | °C | Meaning open |
| 03-001 | HKR1 | Minimum supply temperature HKR1 (Alias 63810008) | `03810048` | `Fusspunkt.Vorlauftemp.Heizen.03.001` | °C | verified |
| 03-002 | HKR1 | Setting value 03-002 (description open; Alias 63820008) | `03820048` | (not polled) | °C | Meaning open |
| 03-012 | HKR1 | Standard outside temperature HKR1 (Alias 63830008) | `038c0048` | `Norm.Aussentemperatur.03.012` | °C | verified |
| 03-013 | HKR1 | Supply temperature at standard outside temperature HKR1 (raw value 61/2; Alias 63840008) | `038d0048` | `Vorlauftemp.Norm.Aussentemp.03.013` | °C | verified |
| 03-021 | HKR1 | Heating limit HKR1 (Alias list index 5) | `63850008` | `Heizgrenze.03.021` | °C | verified |
| 03-050 | HKR1 | Operating mode heating HKR1 (0 Standby, 1 Automatic, 4 Normal, 5 Economy, 7 Manual) | `03b20048` | `Betriebswahl.Heizkreis.03.050` |  | verified |
| 03-051 | HKR1 | Room setpoint day HKR1 (Alias 63860008) | `03b30048` | `Solltemperatur.Heizbetrieb.03.051` | °C | verified |
| 03-053 | HKR1 | Room setpoint night HKR1 (Alias 63870008) | `03b50048` | `Solltemperatur.Heizbetrieb.Nacht.03.053` | °C | verified |
| 00-001 | HKR2 | Room temperature HKR2 actual | `0081004a` | – | °C | no sensor (0x8000) |
| 00-002 | HKR2 | Supply temperature HKR2 actual | `7784000a` | `Istwert.HKR2.Vorlauftemp.00.002` | °C | verified |
| 00-058 | HKR2 | Relative humidity HKR2 | `00ba004a` | – | % | no sensor (0x8000) |
| 01-001 | HKR2 | Room setpoint HKR2 | `7783000a` | `Raumsollwert.HKR2.01.001` | °C | verified |
| 01-002 | HKR2 | Supply temperature HKR2 setpoint | `7785000a` | `Sollwert.HKR2.Vorlauftemp.01.002` | °C | verified |
| 01-020 | HKR2 | Heating circuit pump HKR2 (%) | `7580000a` | `Status.HKR2.Pumpe.01.020` | % | verified |
| 01-021 | HKR2 | Mixer HKR2 - command signal (no position value) | `7581000a` | `Mischer.HKR2.01.021` |  | verified |
| 02-020 | HKR2 | Average outside temperature HKR2 | `7782000a` | `Aussentemperatur.Mittelwert.HKR2.02.020` | °C | verified |
| 02-051 | HKR2 | Status heating circuit control HKR2 | `7780000a` | `Status.HKR2.02.051` |  | verified |
| 03-000 | HKR2 | Setting value 03-000 (description open; Alias 6380000a) | `0380004a` | (not polled) | °C | Meaning open |
| 03-001 | HKR2 | Minimum supply temperature HKR2 (Alias 6381000a) | `0381004a` | (not polled) | °C | verified |
| 03-002 | HKR2 | Setting value 03-002 (description open; Alias 6382000a) | `0382004a` | (not polled) | °C | Meaning open |
| 03-012 | HKR2 | Standard outside temperature HKR2 (Alias 6383000a) | `038c004a` | (not polled) | °C | verified |
| 03-013 | HKR2 | Supply temperature at standard outside temperature HKR2 (raw value 61/2; Alias 6384000a) | `038d004a` | (not polled) | °C | verified |
| 03-021 | HKR2 | Heating limit HKR2 (Alias 6385000a) | `0395004a` | (not polled) | °C | verified |
| 03-050 | HKR2 | Operating mode heating HKR2 (0 Standby, 1 Automatic, 4 Normal, 5 Economy, 7 Manual) | `03b2004a` | `Betriebswahl.HKR2.03.050` |  | verified |
| 03-051 | HKR2 | Room setpoint day HKR2 (Alias 6386000a) | `03b3004a` | (not polled) | °C | verified |
| 03-053 | HKR2 | Room setpoint night HKR2 (Alias 6387000a) | `03b5004a` | (not polled) | °C | verified |
| 07-009 | HKR2 | Setpoint manual operation HKR2 (Alias 6780000a) | `0789004a` | (not polled) | °C | verified |

**Only visible on the display (no numerical value via eBUS or function is inactive):** 03-044 Summer operating point, 03-045 Summer slope, 03-054 / 03-056 Room temperature day/night (each "–.–"), 05-004 Legionella protection ("–.–"), 04-005 Function name, 04-086 Design variant, 04-089 Date of commissioning (example: 01.01.2016), 04-090 Device identification (example: 12345678), 04-092 Software version (5.98), 04-093 Hardware version (3.03), 04-095 System operator (example: "Ochsner Freak"), 04-096 Installer, 04-097 Planner.
