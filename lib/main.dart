import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/tts_service.dart';
import 'services/vision_service.dart';
import 'services/emergency_service.dart';
import 'services/ocr_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Error getting cameras: $e');
  }
  
  runApp(const BlindNavApp());
}

class BlindNavApp extends StatelessWidget {
  const BlindNavApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Guide Vision',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BlindSafeHomeScreen(),
    );
  }
}

class BlindSafeHomeScreen extends StatefulWidget {
  const BlindSafeHomeScreen({super.key});

  @override
  State<BlindSafeHomeScreen> createState() => _BlindSafeHomeScreenState();
}

class _BlindSafeHomeScreenState extends State<BlindSafeHomeScreen> with WidgetsBindingObserver {
  CameraController? _cameraController;
  final TtsService _ttsService = TtsService();
  late final VisionService _visionService; // Initialized in initState
  late final EmergencyService _emergencyService; 
  late final OcrService _ocrService;
  
  bool _isInitialized = false;
  bool _isProcessing = false;
  bool _autoMode = false;
  Timer? _autoTimer;
  String _lastAnnouncement = "";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Initialize services
    _visionService = VisionService();
    _emergencyService = EmergencyService(_ttsService);
    _ocrService = OcrService(_ttsService);
    
    _initializeServices();
  }

  Future<void> _initializeServices() async {
    // 1. Camera Permissions
    final cameraStatus = await Permission.camera.request();
    if (!cameraStatus.isGranted) {
      _ttsService.speak("Camera permission denied. The app cannot see.");
      return;
    }

    // 2. Initialize TTS
    await _ttsService.initialize();
    _ttsService.speak("Vision Nav ready. Tap screen to detect. Long press for auto mode.");

    // 3. Initialize Vision
    await _visionService.loadModel();
    if (!_visionService.isModelLoaded) {
      _ttsService.speak("Warning. Visual model failed to load.");
    }
    
    // 4. Initialize Emergency Service
    await _emergencyService.initialize();
    _emergencyService.onSmsSent = () {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("🆘 EMERGENCY ALERT SENT SUCCESSFULLY"),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 4),
          ),
        );
      }
    };
    
    // Set up fall detection listener
    _emergencyService.addListener(_handleEmergencyUpdate);

    if (_emergencyService.isConfigured && _emergencyService.isMonitoring == false) {
      _emergencyService.startMonitoring();
    }

    // 5. Setup Camera
    if (cameras.isNotEmpty) {
      await _initializeCamera(cameras.first);
    }
  }

  Future<void> _initializeCamera(CameraDescription camera) async {
    _cameraController = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _cameraController!.initialize();
      if (mounted) setState(() => _isInitialized = true);
    } catch (e) {
      _ttsService.speak("Camera error.");
    }
  }

  /// ----------------------------------------------------------
  /// CORE LOGIC: IMAGE PROCESSING
  /// ----------------------------------------------------------

  Future<void> _performDetection() async {
    if (_isProcessing || _cameraController == null || !_cameraController!.value.isInitialized) return;
    
    // Don't perform detection if fall alert is active
    if (_emergencyService.isAlertActive) return;
    
    _isProcessing = true;
    HapticFeedback.lightImpact(); // Tactile feedback that scan started

    try {
      await _cameraController!.setFlashMode(FlashMode.off);
      final XFile photo = await _cameraController!.takePicture();
      
      final detections = await _visionService.processImageFile(photo.path);
      
      // Cleanup image logic - removing explicit delete here, handled at end
      // try { await File(photo.path).delete(); } catch (_) {}

      // Analyze results
      String announcement = "";
      bool shouldReadText = false;
      
      if (detections.isEmpty) {
        announcement = "Pathway clear."; 
      } else {
        // Use the new guidance logic
        announcement = _generateSafeNavigationMessage(detections);
        
        // Check if we need to trigger OCR
        final sign = detections.firstWhere(
            (d) => d.label.toLowerCase().contains('sign') || d.label.toLowerCase().contains('text'),
            orElse: () => DetectedObject(label: "", confidence: 0, left:0, top:0, width:0, height:0, distanceMeters: 0)
        );
        
        if (sign.label.isNotEmpty && !announcement.contains("blocked")) {
           // If path isn't critically blocked, offer to read sign
           // We append this optionally or handle it? 
           // For now, let's just flag it. The user wants guidance first.
           shouldReadText = true;
           if (announcement == "Pathway clear.") {
             announcement = "Sign board detected. Reading text...";
           }
        }
      }

      // Speak the announcement if available
      if (announcement.isNotEmpty) {
        // Don't interrupt if we are about to do OCR which will also speak
        if (shouldReadText) {
           await _ttsService.speak(announcement); // Say "Reading text..."
        } else {
           _ttsService.speak(announcement); 
           _lastAnnouncement = announcement;
        }
      }

      // Cleanup image immediately if not needed for OCR
      if (!shouldReadText) {
         try { await File(photo.path).delete(); } catch (_) {}
      } else {
         // Perform OCR
         await _ocrService.processImageForText(photo.path);
         // Then clean up
         try { await File(photo.path).delete(); } catch (_) {}
      }

    } catch (e) {
      print("Detection Error: $e");
    } finally {
      _isProcessing = false;
    }
  }

  /// ----------------------------------------------------------
  /// GUIDANCE LOGIC
  /// ----------------------------------------------------------
  
  String _generateSafeNavigationMessage(List<DetectedObject> detections) {
    if (detections.isEmpty) return "Pathway clear.";

    // 1. Filter relevant objects (close enough to be an obstacle, e.g. < 4m)
    // We include small objects too as requested
    final obstacles = detections.where((d) => d.distanceMeters < 4.0).toList();
    
    if (obstacles.isEmpty) return "Pathway clear.";

    // 2. Check for Critical Hazards (Stairs/Doors)
    final stairs = obstacles.where((d) => d.isStaircase).toList();
    if (stairs.isNotEmpty) {
      final s = stairs.first;
      return "Caution. Stairs detected ${s.locationLabel}, ${s.distanceMeters.toStringAsFixed(1)} meters away. ${s.stepCount > 0 ? '${s.stepCount} steps.' : ''} Approach carefully.";
    }
    
    // Check for Doors explicitly
    final doors = obstacles.where((d) => d.isDoor).toList();
    if (doors.isNotEmpty) {
      final door = doors.first;
      if (door.isDoorOpen) {
         // If open door is roughly distinct, guide towards it?
         // For now, simpler: "Open Door ahead. Proceed through."
         // We check if it is relatively centered
         double doorCenter = door.left + (door.width / 2);
         if (doorCenter > 0.3 && doorCenter < 0.7) {
            return "Open Door ahead, ${door.distanceMeters.toStringAsFixed(1)} meters away. Proceed through.";
         }
      } else {
         return "Closed Door ahead, ${door.distanceMeters.toStringAsFixed(1)} meters away. Stop.";
      }
    }

    // 3. Analyze Sectors for Guidance
    bool leftBlocked = false;
    bool centerBlocked = false;
    bool rightBlocked = false;
    
    DetectedObject? centerObstacle;
    DetectedObject? leftObstacle;
    DetectedObject? rightObstacle;

    // Define sectors: Left (<0.4), Center (0.4-0.6), Right (>0.6)
    // Expanded center zone slightly for safety
    for (var d in obstacles) {
       // Center point of the object
       double objCenter = d.left + (d.width / 2);
       
       if (objCenter < 0.4) {
         leftBlocked = true;
         leftObstacle ??= d;
       } else if (objCenter > 0.6) {
         rightBlocked = true;
         rightObstacle ??= d;
       } else {
         centerBlocked = true;
         centerObstacle ??= d;
       }
    }

    // 4. Generate Instructions
    // Priority: Avoid Center Collision -> Avoid Side Collision
    
    if (centerBlocked) {
       String obs = centerObstacle?.label ?? "Obstacle";
       double dist = centerObstacle?.distanceMeters ?? 0;
       String distStr = "${dist.toStringAsFixed(1)} meters";
       
       if (!leftBlocked && !rightBlocked) {
         return "$obs ahead at $distStr. Move Left or Right.";
       } else if (!leftBlocked) {
         return "$obs ahead at $distStr. Move Left.";
       } else if (!rightBlocked) {
         return "$obs ahead at $distStr. Move Right.";
       } else {
         return "Path blocked by $obs at $distStr. Stop.";
       }
    } 
    
    // Center is clear, check sides to ensure "avoidance" guidance
    if (leftBlocked) {
       return "${leftObstacle?.label} on left, ${leftObstacle?.distanceMeters.toStringAsFixed(1)} meters. Move Right to avoid.";
    } 
    
    if (rightBlocked) {
       return "${rightObstacle?.label} on right, ${rightObstacle?.distanceMeters.toStringAsFixed(1)} meters. Move Left to avoid.";
    }
    
    return "Pathway clear.";
  }

  /// ----------------------------------------------------------
  /// USER INTERACTION HANDLERS (GESTURES)
  /// ----------------------------------------------------------
  
  // Single Tap: Manual Detection
  void _onTap() {
    HapticFeedback.lightImpact(); // Haptic for tap
    if (_autoMode) {
      _ttsService.speak("Pausing auto mode.");
      _toggleAutoMode(); // Turn it off
    } else {
      _performDetection();
    }
  }

  // Long Press: Toggle Auto-Nav Mode
  void _onLongPress() {
    HapticFeedback.heavyImpact(); // Haptic for long press
    _toggleAutoMode();
  }

  void _toggleAutoMode() {
    setState(() => _autoMode = !_autoMode);
    
    if (_autoMode) {
      _ttsService.speak("Continuous navigation started.");
      _autoTimer = Timer.periodic(const Duration(seconds: 4), (_) => _performDetection());
    } else {
      _ttsService.speak("Navigation stopped.");
      _autoTimer?.cancel();
    }
  }

  // Double Tap: Cancel fall alert OR repeat last announcement
  void _onDoubleTap() {
    // If fall alert is active, cancel it
    if (_emergencyService.isAlertActive) {
      _emergencyService.cancelFallAlert();
      return;
    }
    
    // Otherwise, repeat last announcement
    if (_lastAnnouncement.isNotEmpty) {
      _ttsService.speak(_lastAnnouncement, force: true);
    } else {
      _ttsService.speak("No previous detection.");
    }
  }
  
  // Dismiss the fall alert dialog if shown
  
  // Context for fall alert dialog
  BuildContext? _fallAlertDialogContext;
  bool _isDialogMounted = false;
  
  /// Show the fall alert dialog with countdown - Minimal & Premium Design
  void _showFallAlertDialog() {
    if (!mounted || _fallAlertDialogContext != null) return;
    
    HapticFeedback.heavyImpact();
    _isDialogMounted = true;

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierLabel: "Fall Alert",
      barrierColor: Colors.black.withOpacity(0.5), // Semi-transparent top
      pageBuilder: (dialogContext, anim1, anim2) {
        _fallAlertDialogContext = dialogContext;
        return ListenableBuilder(
          listenable: _emergencyService,
          builder: (context, _) {
            // Check for dismissal automatically
            if (!_emergencyService.isAlertActive && _fallAlertDialogContext != null) {
               WidgetsBinding.instance.addPostFrameCallback((_) {
                 if (_fallAlertDialogContext != null) {
                    _isDialogMounted = false;
                    Navigator.of(_fallAlertDialogContext!).pop();
                    _fallAlertDialogContext = null;
                 }
               });
            }
            
            return PopScope(
              canPop: false, // Prevent back button dismiss
              child: Scaffold(
                backgroundColor: Colors.transparent, // Transparent scaffold
                body: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onDoubleTap: () {
                    _emergencyService.cancelFallAlert();
                  },
                  child: Column(
                    children: [
                      const Spacer(), // Top half is empty (but tappable by GestureDetector)
                      Container(
                        height: MediaQuery.of(context).size.height * 0.55, // Bottom ~55%
                        width: double.infinity,
                        decoration: const BoxDecoration(
                          color: Color(0xFF1A0000), // Very dark red
                          borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
                          boxShadow: [BoxShadow(color: Colors.redAccent, blurRadius: 20, spreadRadius: 2)],
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.warning_rounded, color: Colors.redAccent, size: 60),
                            const SizedBox(height: 10),
                            Text(
                              "FALL DETECTED",
                              style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 1.5),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 120,
                                  height: 120,
                                  child: CircularProgressIndicator(
                                    value: _emergencyService.remainingSeconds / 10,
                                    strokeWidth: 8,
                                    color: Colors.redAccent,
                                    backgroundColor: Colors.white10,
                                  ),
                                ),
                                Text(
                                  "${_emergencyService.remainingSeconds}",
                                  style: const TextStyle(color: Colors.white, fontSize: 50, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            const Spacer(),
                            const Text(
                              "Sending Alert In...",
                              style: TextStyle(color: Colors.white70, fontSize: 16),
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              "DOUBLE TAP ANYWHERE\nTO CANCEL",
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 1),
                            ),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      _isDialogMounted = false;
      _fallAlertDialogContext = null;
    });
  }

  void _handleEmergencyUpdate() {
    if (!mounted) return;
    
    // If an alert is active but the dialog is NOT currently showing, open it immediately
    if (_emergencyService.isAlertActive && _fallAlertDialogContext == null) {
      _showFallAlertDialog();
    }
    
    // Refresh main UI state (e.g., to update monitoring status colors)
    setState(() {});
  }

  Widget _buildAlertButton(String label, Color color, VoidCallback onTap) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 20),
          alignment: Alignment.center,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _buildLanguageButton(String label, bool isSelected, VoidCallback onTap) {
    return Material(
      color: isSelected ? Colors.orangeAccent : Colors.white.withOpacity(0.05),
      borderRadius: BorderRadius.circular(15),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(15),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 18),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.black : Colors.white, 
              fontSize: 16, 
              fontWeight: FontWeight.bold
            ),
          ),
        ),
      ),
    );
  }

  // Triple Tap: Emergency Settings (Accessibility-friendly "Hidden" menu)
  void _onTripleTap() {
    HapticFeedback.heavyImpact();
    _showEmergencyDialog();
  }

  /// ----------------------------------------------------------
  /// EMERGENCY CONFIGURATION UI
  /// ----------------------------------------------------------
  
  void _showEmergencyDialog() {
    final TextEditingController numberController = TextEditingController();
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Container(
            decoration: const BoxDecoration(
              color: Color(0xFF121212),
              borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
            ),
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom + 30,
              top: 30,
              left: 25,
              right: 25,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      "Emergency Settings",
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(context),
                    )
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  "Contacts added here will receive SOS messages with your location if a fall or shake is detected.",
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 25),
                
                // Contacts List
                if (_emergencyService.emergencyNumbers.isNotEmpty) ...[
                   const Text("SAVED CONTACTS", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.5)),
                   const SizedBox(height: 10),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 180),
                     decoration: BoxDecoration(
                       color: Colors.white.withOpacity(0.05),
                       borderRadius: BorderRadius.circular(15)
                     ),
                     child: ListView.separated(
                       shrinkWrap: true,
                       padding: EdgeInsets.zero,
                       itemCount: _emergencyService.emergencyNumbers.length,
                       separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.05), height: 1),
                       itemBuilder: (c, i) {
                         final num = _emergencyService.emergencyNumbers[i];
                         return ListTile(
                           title: Text(num, style: const TextStyle(color: Colors.white, fontSize: 18)),
                           trailing: IconButton(
                             icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                             onPressed: () async {
                               await _emergencyService.removeEmergencyNumber(num);
                               setDialogState((){});
                               setState((){});
                               _ttsService.speak("Contact removed.");
                             }
                           ),
                         );
                       }
                     ),
                   ),
                   const SizedBox(height: 25),
                ],

                // Add new number UI
                const Text("ADD NEW CONTACT", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.5)),
                const SizedBox(height: 10),
                TextField(
                  controller: numberController,
                  keyboardType: TextInputType.phone,
                  style: const TextStyle(color: Colors.white, fontSize: 20),
                  decoration: InputDecoration(
                    hintText: "+91 00000 00000",
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.2)),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
                    prefixIcon: const Icon(Icons.phone, color: Colors.white54),
                  ),
                ),
                const SizedBox(height: 15),
                ElevatedButton(
                  onPressed: () async {
                    final newNum = numberController.text.trim();
                    if (newNum.isNotEmpty) {
                      await _emergencyService.addEmergencyNumber(newNum);
                      numberController.clear();
                      setDialogState((){});
                      setState((){});
                      _ttsService.speak("Number added successfully.");
                    } else {
                      _ttsService.speak("Please enter a phone number first.");
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                  child: const Text("CONFIRM & ADD NUMBER", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
                
                const SizedBox(height: 30),

                // Language Selection
                const Text("VOICE GUIDANCE LANGUAGE", style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.w900, fontSize: 12, letterSpacing: 1.5)),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildLanguageButton(
                        "English", 
                        !_ttsService.isMalayalam, 
                        () async {
                          await _ttsService.setLanguage("en-US");
                          setDialogState((){});
                          setState((){});
                        }
                      ),
                    ),
                    const SizedBox(width: 15),
                    Expanded(
                      child: _buildLanguageButton(
                        "മലയാളം", 
                        _ttsService.isMalayalam, 
                        () async {
                          await _ttsService.setLanguage("ml-IN");
                          setDialogState((){});
                          setState((){});
                        }
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 30),
                
                // Monitoring Toggle
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: _emergencyService.isMonitoring ? Colors.redAccent.withOpacity(0.1) : Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(color: _emergencyService.isMonitoring ? Colors.redAccent.withOpacity(0.3) : Colors.transparent),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Active Monitoring", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                          Text(
                            _emergencyService.isMonitoring 
                              ? "Active & Detecting" 
                              : "Currently Disabled",
                            style: TextStyle(color: _emergencyService.isMonitoring ? Colors.redAccent : Colors.white54, fontSize: 14),
                          ),
                        ],
                      ),
                      Switch(
                        value: _emergencyService.isMonitoring, 
                        activeColor: Colors.redAccent,
                        onChanged: (val) {
                           if (val) {
                             if (_emergencyService.emergencyNumbers.isEmpty) {
                               _ttsService.speak("Add a contact first before enabling monitoring.");
                               return;
                             }
                             _emergencyService.startMonitoring();
                           } else {
                             _emergencyService.stopMonitoring();
                           }
                           setDialogState((){});
                           setState((){});
                        }
                      )
                    ],
                  ),
                )
              ],
            ),
          );
        }
      ),
    );
  }


  /// ----------------------------------------------------------
  /// APP LIFECYCLE
  /// ----------------------------------------------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_cameraController == null || !_cameraController!.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _cameraController?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      if (cameras.isNotEmpty) _initializeCamera(cameras.first);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraController?.dispose();
    _ttsService.dispose();
    _visionService.dispose();
    _emergencyService.stopMonitoring();
    _autoTimer?.cancel();
    super.dispose();
  }

  /// ----------------------------------------------------------
  /// MAIN UI BUILD (Full Screen Gestures)
  /// ----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // Catch touches everywhere
          onTap: _onTap,
          onDoubleTap: _onDoubleTap,
          onLongPress: _onLongPress,
          onDoubleTapDown: (_) {}, // Consumes double tap logic
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Camera Preview (Dimmed for low vision / battery)
              if (_isInitialized && _cameraController != null)
                Opacity(
                  opacity: 0.6, // Dimmed
                  child: CameraPreview(_cameraController!),
                )
              else 
                const Center(child: CircularProgressIndicator()),

              // 2. High Contrast Overlay (Centered)
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.touch_app, color: Colors.white, size: 80),
                    const SizedBox(height: 20),
                    Text(
                      _autoMode ? "AUTO MODE ACTIVE\nScanning..." : "TAP SCREEN\nto detect",
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 40),
                    if (_emergencyService.isMonitoring)
                      const Chip(
                        label: Text("Fall Monitor ON"),
                        backgroundColor: Colors.redAccent,
                        avatar: Icon(Icons.shield, color: Colors.white),
                      )
                  ],
                ),
              ),

              // 3. Settings Button (Top Right)
              Positioned(
                top: 10,
                right: 10,
                child: IconButton(
                  icon: const Icon(Icons.settings, color: Colors.white, size: 30),
                  onPressed: _showEmergencyDialog,
                  tooltip: "Emergency Settings",
                ),
              ),

            ],
          ),
        ),
      ),

    );
  }
}



