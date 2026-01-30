import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service for handling Text-to-Speech announcements
class TtsService {
  // Singleton pattern
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  bool _isInitialized = false;
  bool _isSpeaking = false;
  String _currentLanguage = "en-US"; // "en-US" or "ml-IN"
  late SharedPreferences _prefs;

  Future<void> initialize() async {
    if (_isInitialized) return;
    
    _prefs = await SharedPreferences.getInstance();
    _currentLanguage = _prefs.getString('tts_language') ?? "en-US";

    await _flutterTts.setLanguage(_currentLanguage);
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    
    _flutterTts.setStartHandler(() {
      _isSpeaking = true;
    });
    
    _flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
    });
    
    _flutterTts.setErrorHandler((msg) {
      _isSpeaking = false;
    });
    
    _isInitialized = true;
  }

  /// Speak a message. If already speaking, will not interrupt unless [force] is true.
  Future<void> speak(String message, {bool force = false}) async {
    if (!_isInitialized) await initialize();
    
    if (_isSpeaking && !force) return;
    
    if (force && _isSpeaking) {
      await _flutterTts.stop();
    }
    
    String translatedMessage = _translateIfNeedBe(message);
    await _flutterTts.speak(translatedMessage);
  }

  String get currentLanguage => _currentLanguage;

  bool get isMalayalam => _currentLanguage == "ml-IN";

  /// Translate a string based on current language
  String translate(String text) {
    if (_currentLanguage == "en-US") return text;
    return _translateIfNeedBe(text);
  }

  Future<void> setLanguage(String langCode) async {
    _currentLanguage = langCode;
    await _flutterTts.setLanguage(langCode);
    await _prefs.setString('tts_language', langCode);
    
    if (langCode == "ml-IN") {
       speak("ഭാഷ മലയാളത്തിലേക്ക് മാറ്റി", force: true);
    } else {
       speak("Language changed to English", force: true);
    }
  }

  String _translateIfNeedBe(String message) {
    if (_currentLanguage == "en-US") return message;

    // Malayalam translation dictionary
    // We handle common phrases and then dynamic parts
    String malayalam = message;

    // Priority replacements (Full phrases)
    final map = {
      "Pathway clear.": "മുന്നിൽ തടസ്സങ്ങൾ ഒന്നുമില്ല.",
      "Caution.": "ശ്രദ്ധിക്കുക.",
      "Approach carefully.": "സൂക്ഷിച്ചു നീങ്ങുക.",
      "Open Door ahead": "മുന്നിൽ തുറന്ന വാതിലുണ്ട്",
      "Closed Door ahead": "മുന്നിൽ അടച്ച വാതിലുണ്ട്",
      "Proceed through.": "അതിലൂടെ നീങ്ങുക.",
      "Move Left": "ഇടത്തോട്ട് നീങ്ങുക",
      "Move Right": "വലത്തോട്ട് നീങ്ങുക",
      "Move Left or Right.": "ഇടത്തോട്ടൊ വലത്തോട്ടൊ നീങ്ങുക.",
      "Stop.": "നിൽക്കുക.",
      "ahead": "മുന്നിൽ",
      "at": "",
      "meters": "മീറ്റർ",
      "away": "അകലെ",
      "on left": "ഇടത് വശത്ത്",
      "on right": "വലത് വശത്ത്",
      "to avoid.": "മാറി നീങ്ങുക.",
      "Path blocked by": "വഴി തടസ്സപ്പെടുത്തിയിരിക്കുന്നത്",
      "Sign board detected. Reading text...": "ബോർഡ് കണ്ടെത്തി. വായിക്കുന്നു...",
      "No previous detection.": "മുമ്പ് തിരിച്ചറിഞ്ഞ വിവരങ്ങൾ ലഭ്യമല്ല.",
      "Navigation stopped.": "നാവിഗേഷൻ നിർത്തി.",
      "Continuous navigation started.": "നാവിഗേഷൻ തുടങ്ങി.",
      "Emergency detection disabled.": "എമർജൻസി സഹായം നിർത്തി.",
      "Emergency fall and shake detection enabled.": "എമർജൻസി സഹായം തുടങ്ങി.",
      "Fall detected!": "വീഴ്ച സംഭവിച്ചു!",
      "Alert will be sent in 10 seconds.": "സന്ദേശം 10 സെക്കൻഡിനുള്ളിൽ പോകും.",
      "Double tap screen to cancel.": "റദ്ദാക്കാൻ സ്ക്രീനിൽ രണ്ട് തവണ തൊടുക.",
      "Sending emergency alerts now.": "സന്ദേശങ്ങൾ അയക്കുന്നു.",
      "Alert cancelled. You are safe.": "അഭ്യർത്ഥന റദ്ദാക്കി. നിങ്ങൾ സുരക്ഷിതനാണ്.",
      "Contact removed.": "കോൺടാക്റ്റ് നീക്കം ചെയ്തു.",
      "Number added successfully.": "നമ്പർ ചേർത്തു.",
      "Please enter a phone number first.": "ആദ്യം ഒരു ഫോൺ നമ്പർ നൽകുക.",
      "Pausing auto mode.": "നാവിഗേഷൻ നിർത്തുന്നു.",
      "Fall detected! Double tap anywhere to cancel or stay still to send alert.": "വീഴ്ച സംഭവിച്ചു! റദ്ദാക്കാൻ സ്ക്രീനിൽ രണ്ട് തവണ തൊടുക.",
      "Fall detected! Alert will be sent in 10 seconds. Double tap screen to cancel.": "വീഴ്ച സംഭവിച്ചു! സന്ദേശം 10 സെക്കൻഡിനുള്ളിൽ പോകും. റദ്ദാക്കാൻ സ്ക്രീനിൽ രണ്ട് തവണ തൊടുക.",
      "DOUBLE TAP ANYWHERE\nTO CANCEL": "റദ്ദാക്കാൻ രണ്ട് തവണ തൊടുക",
      "FALL DETECTED": "വീഴ്ച സംഭവിച്ചു",
      "Sending Alert In...": "സന്ദേശം അയക്കുന്നു...",
      "Emergency Settings": "എമർജൻസി ക്രമീകരണങ്ങൾ",
      "SAVED CONTACTS": "സേവ് ചെയ്ത നമ്പറുകൾ",
      "ADD NEW CONTACT": "പുതിയ നമ്പർ ചേർക്കുക",
      "CONFIRM & ADD NUMBER": "നമ്പർ സ്ഥിരീകരിക്കുക",
      "VOICE GUIDANCE LANGUAGE": "ഭാഷ മാറ്റുക",
      "Active Monitoring": "സജീവമായി നിരീക്ഷിക്കുക",
      "Open Door ahead. Proceed through.": "മുന്നിൽ തുറന്ന വാതിലുണ്ട്. അതിലൂടെ നീങ്ങുക.",
      "Closed Door ahead. Stop.": "മുന്നിൽ അടച്ച വാതിലുണ്ട്. നിൽക്കുക.",
      
      // Objects
      "person": "ആൾ",
      "chair": "കസേര",
      "car": "കാർ",
      "staircase": "ഗോവണി",
      "stairs": "ഗോവണി",
      "door": "വാതിൽ",
      "traffic light": "ട്രാഫിക് സിഗ്നൽ",
      "bottle": "കുപ്പി",
      "laptop": "ലാപ്ടോപ്പ്",
      "cell phone": "ഫോൺ",
      "cup": "കപ്പ്",
      "book": "പുസ്തകം",
      "obstacle": "തടസ്സം",
      
      // Colors
      "Red": "ചുവപ്പ്",
      "Green": "പച്ച",
      "Yellow": "മഞ്ഞ",
      "Blue": "നീല",
      "White": "വെള്ള",
      "Black": "കറുപ്പ്",
      "Gray": "ചാരനിറം",
      "Orange": "ഓറഞ്ച്",
      "Brown": "തവിട്ടുനിറം",
    };

    // Convert map keys to a list and sort by length (descending) 
    // to ensure full phrases are matched before individual words
    final sortedKeys = map.keys.toList()..sort((a, b) => b.length.compareTo(a.length));

    for (var en in sortedKeys) {
      malayalam = malayalam.replaceAll(en, map[en]!);
    }

    return malayalam;
  }

  /// Stop current speech
  Future<void> stop() async {
    await _flutterTts.stop();
    _isSpeaking = false;
  }

  /// Announce staircase detection with distance and step count
  Future<void> announceStaircase(double distanceMeters, int stepCount) async {
    final distance = distanceMeters.toStringAsFixed(1);
    String message;
    
    if (stepCount > 0) {
      message = "Caution! Staircase detected at $distance meters with approximately $stepCount steps. Please proceed with care.";
    } else {
      message = "Caution! Staircase detected at $distance meters. Please proceed with care.";
    }
    
    await speak(message, force: true);
  }
  
  /// Announce door detection with open/close status
  Future<void> announceDoor(String doorLabel, double distanceMeters, bool isOpen) async {
    final distance = distanceMeters.toStringAsFixed(1);
    final status = isOpen ? "open" : "closed";
    final message = "$doorLabel detected at $distance meters. The door appears to be $status.";
    await speak(message, force: true);
  }

  /// Announce general obstacle
  Future<void> announceObstacle(String objectName, double distanceMeters) async {
    final distance = distanceMeters.toStringAsFixed(1);
    await speak("$objectName detected at $distance meters", force: false);
  }

  void dispose() {
    _flutterTts.stop();
  }
}
