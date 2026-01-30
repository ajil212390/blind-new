import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'tts_service.dart';

class EmergencyService extends ChangeNotifier {
  final TtsService _ttsService;
  static const _channel = MethodChannel('com.blindnav/sms');
  VoidCallback? onSmsSent;
  
  // Callback for showing fall alert dialog
  Function(BuildContext context)? onFallDetected;
  
  // Configuration
  List<String> _emergencyNumbers = []; 
  bool _isMonitoring = false;
  
  // Shake detection
  StreamSubscription<UserAccelerometerEvent>? _shakeSubscription;
  DateTime? _lastShakeTime;
  int _shakeCount = 0;
  static const double _shakeThreshold = 30.0; // Reduced for better detection
  static const int _minShakeCount = 6; // Reduced for better detection
  static const int _shakeWindowMs = 1500; // Increased window for natural movements

  // Fall alert state
  bool _isAlertActive = false;
  Timer? _countdownTimer;
  int _remainingSeconds = 10;
  
  late SharedPreferences _prefs;
  static const String _keyNumbers = "emergency_numbers";
  
  // Fall detection thresholds
  // Gravity is ~9.8 m/s^2.
  // Free fall is near 0.
  // Impact is a sudden spike.
  static const double _freeFallThreshold = 5.0; // < 3.0 m/s^2 implies falling
  static const double _impactThreshold = 50.0; // > 25.0 m/s^2 implies hard impact
  
  bool _potentialFallDetected = false;
  DateTime? _lastFallTime;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  
  Function(String)? onLog;

  EmergencyService(this._ttsService);
  
  bool get isConfigured => _emergencyNumbers.isNotEmpty;
  bool get isMonitoring => _isMonitoring;
  List<String> get emergencyNumbers => _emergencyNumbers;
  bool get isAlertActive => _isAlertActive;
  int get remainingSeconds => _remainingSeconds;

  Future<void> addEmergencyNumber(String number) async {
    if (!_emergencyNumbers.contains(number)) {
      _emergencyNumbers.add(number);
      await _prefs.setStringList(_keyNumbers, _emergencyNumbers);
    }
  }

  Future<void> removeEmergencyNumber(String number) async {
    _emergencyNumbers.remove(number);
    await _prefs.setStringList(_keyNumbers, _emergencyNumbers);
  }
  
  Future<void> initialize() async {
    _prefs = await SharedPreferences.getInstance();
    _emergencyNumbers = _prefs.getStringList(_keyNumbers) ?? [];
    
    // Migration check (if old key exists)
    String? oldNum = _prefs.getString("emergency_number");
    if (oldNum != null && oldNum.isNotEmpty && !_emergencyNumbers.contains(oldNum)) {
       _emergencyNumbers.add(oldNum);
       await _prefs.setStringList(_keyNumbers, _emergencyNumbers);
       await _prefs.remove("emergency_number"); // Cleanup
    }

    // Request SMS and Location permissions early
    await [
      Permission.sms,
      Permission.location,
      Permission.phone, // READ_PHONE_STATE
    ].request();
    
    // Specifically check for READ_SMS if needed by plugin
    await Permission.sms.request();
  }

  void startMonitoring() {
    if (_isMonitoring) return;
    if (_emergencyNumbers.isEmpty) {
      _ttsService.speak("Please set at least one emergency number first.");
      return;
    }
    
    _isMonitoring = true;
    _ttsService.speak("Emergency fall and shake detection enabled.");
    
    // 1. Fall Monitor
    _accelerometerSubscription = accelerometerEventStream().listen((AccelerometerEvent event) {
      _analyzeSensorData(event);
    });

    // 2. Shake Monitor
    HapticFeedback.mediumImpact(); // Confirmation vibration
    _shakeSubscription = userAccelerometerEventStream().listen((UserAccelerometerEvent event) {
      _analyzeShakeData(event);
    });
  }

  void stopMonitoring() {
    _accelerometerSubscription?.cancel();
    _shakeSubscription?.cancel();
    _isMonitoring = false;
    _ttsService.speak("Emergency detection disabled.");
  }

  void _analyzeShakeData(UserAccelerometerEvent event) {
    // Magnitude of user acceleration (excluding gravity)
    double gForce = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    if (gForce > _shakeThreshold) {
      final now = DateTime.now();
      // Reset count if too much time passed since last shake
      if (_lastShakeTime != null && now.difference(_lastShakeTime!).inMilliseconds > _shakeWindowMs) {
        _shakeCount = 0;
      }
      
      _lastShakeTime = now;
      _shakeCount++;
      
      if (_shakeCount >= _minShakeCount) {
        _shakeCount = 0; // Reset
        print("Shake Detected!");
        if (!_isAlertActive) {
           _ttsService.speak("Shake detected.");
           _triggerFallAlert(); // Reuse fall logic
        }
      }
    }
  }

  void _analyzeSensorData(AccelerometerEvent event) {
    // Calculate total G-force magnitude
    double gForce = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
    
    // Logic: Free fall followed immediately by impact
    
    if (gForce < _freeFallThreshold) {
      // Phone is in free fall
      _potentialFallDetected = true;
      _lastFallTime = DateTime.now();
    } 
    else if (_potentialFallDetected && gForce > _impactThreshold) {
      // Check if this impact happened shortly after the fall (within 1 second)
      if (_lastFallTime != null && 
          DateTime.now().difference(_lastFallTime!).inMilliseconds < 1000) {
        
        _triggerFallAlert();
        _potentialFallDetected = false; // Reset
      }
    }
    
    // Reset potential fall if too much time passes
    if (_potentialFallDetected && 
        _lastFallTime != null && 
        DateTime.now().difference(_lastFallTime!).inSeconds > 1) {
      _potentialFallDetected = false;
    }
  }

  /// Trigger the fall alert - this will invoke the callback to show dialog
  void _triggerFallAlert() {
    if (_isAlertActive) return; // Prevent multiple alerts
    
    stopMonitoring(); // Stop sensors immediately while alert is pending
    _isAlertActive = true;
    _remainingSeconds = 10;
    
    HapticFeedback.heavyImpact();
    _ttsService.speak("Fall detected! Alert will be sent in 10 seconds. Double tap screen to cancel.", force: true);
    
    // Notify UI immediately to show screen
    notifyListeners();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      _remainingSeconds--;
      notifyListeners();
      
      if (_remainingSeconds <= 3 && _remainingSeconds > 0) {
        _ttsService.speak("$_remainingSeconds", force: true);
      }
      
      if (_remainingSeconds <= 0) {
        timer.cancel();
        _countdownTimer = null;
        _isAlertActive = false;
        notifyListeners(); // Close UI immediately
        _remainingSeconds = 10; // Reset for next time
        
        // Trigger send in background
        _sendEmergencyAlert();
      }
    });
  }
  
  /// Cancel the fall alert (called from double tap or button)
  void cancelFallAlert() {
    if (!_isAlertActive) return;
    
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _isAlertActive = false;
    _remainingSeconds = 10;
    
    HapticFeedback.mediumImpact();
    notifyListeners();
    
    // Restart monitoring after a short delay so it doesn't immediately re-trigger
    Future.delayed(const Duration(seconds: 3), () {
      if (!_isAlertActive && _emergencyNumbers.isNotEmpty) {
        startMonitoring();
      }
    });
  }

  /// Send the emergency alert immediately, bypassing the countdown
  Future<void> triggerSendImmediately() async {
    if (!_isAlertActive) return;
    
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _isAlertActive = false;
    notifyListeners();
    
    await _sendEmergencyAlert();
  }

  Future<void> _sendEmergencyAlert() async {
    // Monitoring already stopped by _triggerFallAlert
    
    await _ttsService.speak("Sending emergency alerts now.", force: true);
    
    try {
      Position position;
      try {
        position = await _determinePosition();
      } catch (locErr) {
        print("Location Error: $locErr");
        await _ttsService.speak("Failed to get location. Sending alert without it.");
        position = Position(longitude: 0, latitude: 0, timestamp: DateTime.now(), accuracy: 0, altitude: 0, heading: 0, speed: 0, speedAccuracy: 0, altitudeAccuracy: 0, headingAccuracy: 0);
      }

      String mapLink = position.latitude != 0 
          ? "https://www.google.com/maps/search/?api=1&query=${position.latitude},${position.longitude}"
          : "Location unavailable";
      
      String message = "EMERGENCY: User's phone has detected a fall or SOS shake. $mapLink";
      
      int successCount = 0;
      for (String number in _emergencyNumbers) {
        try {
          await _sendSMS(message, recipient: number);
          successCount++;
        } catch (e) {
          print("Error sending to $number: $e");
        }
      }
      
      if (successCount > 0) {
        onSmsSent?.call();
        await _ttsService.speak("Emergency messages sent to $successCount contacts.");
      } else {
        await _ttsService.speak("Failed to send any emergency messages.");
      }

    } catch (e) {
      print("General Emergency Error: $e");
      await _ttsService.speak("Critical failure in emergency protocol.");
    }

    // Restart monitoring after cooldown
    await Future.delayed(const Duration(seconds: 10));
    if (_emergencyNumbers.isNotEmpty) {
       startMonitoring(); 
    }
  }

  Future<void> _sendSMS(String message, {required String recipient}) async {
    try {
      final bool? result = await _channel.invokeMethod('sendSms', {
        'phone': recipient,
        'message': message,
      });
      
      if (result == true) {
        print('SMS Sent successfully via MethodChannel to $recipient');
      } else {
        throw Exception('MethodChannel reported failure');
      }
    } on PlatformException catch (e) {
      throw Exception('MethodChannel error: ${e.message}');
    }
  }

  Future<Position> _determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _ttsService.speak("Location services are disabled. Please turn on your GPS.");
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }
    
    return await Geolocator.getCurrentPosition();
  }
}
