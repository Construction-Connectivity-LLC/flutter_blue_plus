// Copyright 2017, Paul DeMarco.
// All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of flutter_blue_plus;

class FlutterBluePlus {
  final MethodChannel _channel =
      const MethodChannel('flutter_blue_plus/methods');
  final EventChannel _stateChannel =
      const EventChannel('flutter_blue_plus/state');
  final StreamController<MethodCall> _methodStreamController =
      StreamController.broadcast(); // ignore: close_sinks
  Stream<MethodCall> get _methodStream => _methodStreamController
      .stream; // Used internally to dispatch methods from platform.

  /// Cached broadcast stream for FlutterBlue.state events
  /// Caching this stream allows for more than one listener to subscribe
  /// and unsubscribe apart from each other,
  /// while allowing events to still be sent to others that are subscribed
  Stream<BluetoothState>? _stateStream;

  /// Singleton boilerplate
  FlutterBluePlus._() {
    _channel.setMethodCallHandler((MethodCall call) async {
      _methodStreamController.add(call);
    });

    setLogLevel(logLevel);
  }

  static final FlutterBluePlus _instance = FlutterBluePlus._();

  static FlutterBluePlus get instance => _instance;

  /// Log level of the instance, default is all messages (debug).
  LogLevel _logLevel = LogLevel.debug;

  LogLevel get logLevel => _logLevel;

  /// Checks whether the device supports Bluetooth
  Future<bool> get isAvailable =>
      _channel.invokeMethod('isAvailable').then<bool>((d) => d);

  /// Return the friendly Bluetooth name of the local Bluetooth adapter
  Future<String> get name =>
      _channel.invokeMethod('name').then<String>((d) => d);

  /// Checks if Bluetooth functionality is turned on
  Future<bool> get isOn => _channel.invokeMethod('isOn').then<bool>((d) => d);

  Future<void> openBluetoothSettings() {
    return _channel.invokeMethod('openBluetoothSettings');
  }

  /// Tries to turn on Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned on.
  /// You have to listen for a stateChange to ON to ensure bluetooth is already running
  ///
  /// Returns false if an error occured or bluetooth is already running
  ///
  Future<bool> turnOn() {
    return _channel.invokeMethod('turnOn').then<bool>((d) => d);
  }

  /// Tries to turn off Bluetooth (Android only),
  ///
  /// Returns true if bluetooth is being turned off.
  /// You have to listen for a stateChange to OFF to ensure bluetooth is turned off
  ///
  /// Returns false if an error occured
  ///
  Future<bool> turnOff() {
    return _channel.invokeMethod('turnOff').then<bool>((d) => d);
  }

  final BehaviorSubject<bool> _isScanning = BehaviorSubject.seeded(false);

  Stream<bool> get isScanning => _isScanning.stream;

  final BehaviorSubject<List<ScanResult>> _scanResults =
      BehaviorSubject.seeded([]);

  /// Returns a stream that is a list of [ScanResult] results while a scan is in progress.
  ///
  /// The list emitted is all the scanned results as of the last initiated scan. When a scan is
  /// first started, an empty list is emitted. The returned stream is never closed.
  ///
  /// One use for [scanResults] is as the stream in a StreamBuilder to display the
  /// results of a scan in real time while the scan is in progress.
  Stream<List<ScanResult>> get scanResults => _scanResults.stream;

  final PublishSubject _stopScanPill = PublishSubject();

  /// Gets the current state of the Bluetooth module
  Stream<BluetoothState> get state async* {
    yield await _channel
        .invokeMethod('state')
        .then((buffer) => protos.BluetoothState.fromBuffer(buffer))
        .then((s) => BluetoothState.values[s.state.value]);

    _stateStream ??= _stateChannel
        .receiveBroadcastStream()
        .map((buffer) => protos.BluetoothState.fromBuffer(buffer))
        .map((s) => BluetoothState.values[s.state.value])
        .doOnCancel(() => _stateStream = null);

    yield* _stateStream!;
  }

  /// Retrieve a list of connected devices
  Future<List<BluetoothDevice>> get connectedDevices {
    return _channel
        .invokeMethod('getConnectedDevices')
        .then((buffer) => protos.ConnectedDevicesResponse.fromBuffer(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Retrieve a list of bonded devices (Android only)
  Future<List<BluetoothDevice>> get bondedDevices {
    return _channel
        .invokeMethod('getBondedDevices')
        .then((buffer) => protos.ConnectedDevicesResponse.fromBuffer(buffer))
        .then((p) => p.devices)
        .then((p) => p.map((d) => BluetoothDevice.fromProto(d)).toList());
  }

  /// Sets a unique id (required on iOS for restoring app on background-scan)
  /// should be called before any other methods.
  Future setUniqueId(String uniqueid) =>
      _channel.invokeMethod('setUniqueId', uniqueid.toString());

  /// Starts a scan for Bluetooth Low Energy devices and returns a stream
  /// of the [ScanResult] results as they are received.
  ///
  /// timeout calls stopStream after a specified [Duration].
  /// You can also get a list of ongoing results in the [scanResults] stream.
  /// If scanning is already in progress, this will throw an [Exception].
  Stream<ScanResult> scan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<Guid> withDevices = const [],
    List<String> macAddresses = const [],
    List<int> manufacturerIds = const [],
    Duration? timeout,
    bool allowDuplicates = false,
  }) async* {
    var settings = protos.ScanSettings.create()
      ..androidScanMode = scanMode.value
      ..allowDuplicates = allowDuplicates
      ..macAddresses.addAll(macAddresses)
      ..serviceUuids.addAll(withServices.map((g) => g.toString()).toList())
      ..manufacturerIds.addAll(manufacturerIds);

    if (_isScanning.value == true) {
      throw Exception('Another scan is already in progress.');
    }

    // Emit to isScanning
    _isScanning.add(true);

    final killStreams = <Stream>[];
    killStreams.add(_stopScanPill);
    if (timeout != null) {
      killStreams.add(Rx.timer(null, timeout));
    }

    // Clear scan results list
    _scanResults.add(<ScanResult>[]);

    try {
      await _channel.invokeMethod('startScan', settings.writeToBuffer());
    } catch (e) {
      if (kDebugMode) {
        print('Error starting scan.');
      }
      _stopScanPill.add(null);
      _isScanning.add(false);
      rethrow;
    }

    final stream = FlutterBluePlus.instance._methodStream
        .where((m) => m.method == "ScanResult" || m.method == "ScanError")
        .takeUntil(Rx.merge(killStreams))
        .doOnDone(stopScan);

    await for (final event in stream) {
      if (event.method == "ScanResult") {
        final p = protos.ScanResult.fromBuffer(event.arguments);
        final result = ScanResult.fromProto(p);
        final list = _scanResults.value;
        int index = list.indexOf(result);
        if (index != -1) {
          list[index] = result;
        } else {
          list.add(result);
        }
        _scanResults.add(list);
        yield result;
      } else if (event.method == "ScanError") {
        final p = protos.ScanError.fromBuffer(event.arguments);
        final error = ScanError.fromProto(p);
        yield* Stream.error(error);
      }
    }
  }

  /// Starts a scan and returns a future that will complete once the scan has finished.
  ///
  /// Once a scan is started, call [stopScan] to stop the scan and complete the returned future.
  ///
  /// timeout automatically stops the scan after a specified [Duration].
  ///
  /// To observe the results while the scan is in progress, listen to the [scanResults] stream,
  /// or call [scan] instead.
  Future startScan({
    ScanMode scanMode = ScanMode.lowLatency,
    List<Guid> withServices = const [],
    List<int> manufacturerIds = const [],
    List<Guid> withDevices = const [],
    List<String> macAddresses = const [],
    Duration? timeout,
    bool allowDuplicates = false,
  }) async {
    await scan(
            scanMode: scanMode,
            withServices: withServices,
            manufacturerIds: manufacturerIds,
            withDevices: withDevices,
            macAddresses: macAddresses,
            timeout: timeout,
            allowDuplicates: allowDuplicates)
        .drain();
    return _scanResults.value;
  }

  /// Stops a scan for Bluetooth Low Energy devices
  Future stopScan() async {
    await _channel.invokeMethod('stopScan');
    _stopScanPill.add(null);
    _isScanning.add(false);
  }

  /// The list of connected peripherals can include those that are connected
  /// by other apps and that will need to be connected locally using the
  /// device.connect() method before they can be used.
//  Stream<List<BluetoothDevice>> connectedDevices({
//    List<Guid> withServices = const [],
//  }) =>
//      throw UnimplementedError();

  /// Sets the log level of the FlutterBlue instance
  /// Messages equal or below the log level specified are stored/forwarded,
  /// messages above are dropped.
  void setLogLevel(LogLevel level) async {
    await _channel.invokeMethod('setLogLevel', level.index);
    _logLevel = level;
  }

  void _log(LogLevel level, String message) {
    if (level.index <= _logLevel.index) {
      if (kDebugMode) {
        print(message);
      }
    }
  }
}

/// Log levels for FlutterBlue
enum LogLevel {
  emergency,
  alert,
  critical,
  error,
  warning,
  notice,
  info,
  debug,
}

/// State of the bluetooth adapter.
enum BluetoothState {
  unknown,
  unavailable,
  unauthorized,
  turningOn,
  on,
  turningOff,
  off
}

class ScanMode {
  const ScanMode(this.value);

  static const lowPower = ScanMode(0);
  static const balanced = ScanMode(1);
  static const lowLatency = ScanMode(2);
  static const opportunistic = ScanMode(-1);
  final int value;
}

class DeviceIdentifier {
  final String id;

  const DeviceIdentifier(this.id);

  @override
  String toString() => id;

  @override
  int get hashCode => id.hashCode;

  @override
  bool operator ==(other) =>
      other is DeviceIdentifier && compareAsciiLowerCase(id, other.id) == 0;
}

class ScanResult {
  ScanResult.fromProto(protos.ScanResult p)
      : device = BluetoothDevice.fromProto(p.device),
        advertisementData = AdvertisementData.fromProto(p.advertisementData),
        rssi = p.rssi,
        timeStamp = DateTime.now();

  final BluetoothDevice device;
  final AdvertisementData advertisementData;
  final int rssi;
  final DateTime timeStamp;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanResult &&
          runtimeType == other.runtimeType &&
          device == other.device;

  @override
  int get hashCode => device.hashCode;

  @override
  String toString() {
    return 'ScanResult{device: $device, advertisementData: $advertisementData, rssi: $rssi, timeStamp: $timeStamp}';
  }
}

class ScanError {
  final int code;

  ScanError.fromProto(protos.ScanError p) : code = p.code;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScanError &&
          runtimeType == other.runtimeType &&
          code == other.code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() {
    return 'ScanError{code: $code}';
  }
}

class AdvertisementDataElement {
  final int identifier;
  final Uint8List value;

  AdvertisementDataElement({required this.identifier, required this.value});

  @override
  String toString() {
    return 'AdvertisementDataElement{identifier: $identifier, value: $value}';
  }
}

class AdvertisementData {
  final String localName;
  final int? txPowerLevel;
  final bool connectable;
  final Map<int, List<int>> manufacturerData;
  final Map<String, List<int>> serviceData;
  final List<String> serviceUuids;
  final Uint8List rawBytes;
  final List<AdvertisementDataElement> elements;

  /// Parse raw advertising bytes to a List of ADV element
  ///
  /// Documentation comes from here: https://docs.silabs.com/bluetooth/latest/general/adv-and-scanning/bluetooth-adv-data-basics
  static List<AdvertisementDataElement> parseRawAdvertisementBytes(
      Uint8List rawAdvertisingBytes) {
    try {
      List<AdvertisementDataElement> otherData = [];
      for (int advCounter = 0;
          advCounter < rawAdvertisingBytes.length;
          advCounter++) {
        int dataLen = rawAdvertisingBytes[advCounter++];
        if (dataLen == 0) continue;
        int typeIdentifier = rawAdvertisingBytes[advCounter++];
        int offset = (dataLen - 2);
        otherData.add(
          AdvertisementDataElement(
            identifier: typeIdentifier,
            value: rawAdvertisingBytes.sublist(
              advCounter,
              advCounter + (offset + 1),
            ),
          ),
        ); // +1 as end must be the next element
        advCounter += offset;
      }
      return otherData;
    } catch (e) {
      throw Exception(
          "Error while parsing raw advertising bytes: ${e.toString()}, raw bytes: $rawAdvertisingBytes");
    }
  }

  AdvertisementData.fromProto(protos.AdvertisementData p)
      : localName = p.localName,
        txPowerLevel =
            (p.txPowerLevel.hasValue()) ? p.txPowerLevel.value : null,
        connectable = p.connectable,
        manufacturerData = p.manufacturerData,
        serviceData = p.serviceData,
        serviceUuids = p.serviceUuids,
        rawBytes = Uint8List.fromList(p.rawBytes),
        elements = AdvertisementData.parseRawAdvertisementBytes(
            Uint8List.fromList(p.rawBytes));

  @override
  String toString() {
    return 'AdvertisementData{localName: $localName, txPowerLevel: $txPowerLevel, connectable: $connectable, manufacturerData: $manufacturerData, serviceData: $serviceData, serviceUuids: $serviceUuids, rawBytes: ${hex.encode(rawBytes)}}';
  }
}
