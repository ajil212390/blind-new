import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_vision/flutter_vision.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';

/// Represents a detected object
class DetectedObject {
  final String label;
  final double confidence;
  final double left;
  final double top;
  final double width;
  final double height;
  final double distanceMeters;
  final int stepCount;
  final bool isDoorOpen;

  DetectedObject({
    required this.label,
    required this.confidence,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.distanceMeters,
    this.stepCount = 0,
    this.isDoorOpen = false,
  });

  bool get isStaircase => label.toLowerCase().contains('stair');
  bool get isDoor => label.toLowerCase().contains('door');

  /// Returns if the object is Left, Right, or Center
  String get locationLabel {
    // Horizontal center of the bounding box
    final centerX = left + (width / 2);
    
    if (centerX < 0.35) return "on the left";
    if (centerX > 0.65) return "on the right";
    return "at center";
  }
}

/// Vision service using YOLOv8 via flutter_vision and ML Kit Image Labeling
class VisionService {
  late FlutterVision _vision;
  late ImageLabeler _imageLabeler;
  bool _isModelLoaded = false;
  bool _isLabelerLoaded = false;

  // Distance history for smoothing
  final Map<String, List<double>> _distanceHistory = {};
  static const int _historySize = 5;

  // Known object heights for distance estimation (in meters)
  static const Map<String, double> _knownHeightMap = {
    'person': 1.70,
    'chair': 0.85,
    'door': 2.10,
    'open door': 2.10,
    'closed door': 2.10,
    'staircase': 2.50,
    'stairs': 2.50,
    'stair': 0.18, // Single step height
    'laptop': 0.25,
    'cell phone': 0.15,
    'bottle': 0.25,
    'cup': 0.12,
    'book': 0.25,
    'remote': 0.15,
    'keyboard': 0.05,
    'mouse': 0.04,
    'tv': 0.60,
    'monitor': 0.40,
    'table': 0.75,
    'couch': 0.85,
    'bed': 0.50,
    'plant': 0.40,
    'clock': 0.30,
    'vase': 0.25,
    'scissors': 0.20,
    'toy': 0.20,
    'food': 0.10,
    'home good': 0.20,
    'fashion good': 0.30,
  };

  // Average step height in meters (standard stair step)
  static const double _avgStepHeight = 0.18;

  static const double _focalLength = 800.0;

  VisionService() {
    _vision = FlutterVision();
    // Initialize ML Kit Image Labeler with default options (base model)
    final options = ImageLabelerOptions(confidenceThreshold: 0.5);
    _imageLabeler = ImageLabeler(options: options);
    _isLabelerLoaded = true;
  }

  Future<void> loadModel() async {
    if (_isModelLoaded) return;
    
    try {
      // Load standard YOLOv8n TFLite model
      await _vision.loadYoloModel(
        modelPath: 'assets/models/yolov8n.tflite',
        labels: 'assets/models/labels.txt',
        modelVersion: "yolov8",
        quantization: false,
        numThreads: 2,
        useGpu: false,
      );
      
      _isModelLoaded = true;
      print('YOLOv8 Model loaded successfully via flutter_vision');
    } catch (e) {
      print('Failed to load YOLOv8 model: $e');
      _isModelLoaded = false;
    }
  }

  /// Process image from file path using YOLOv8 and ML Kit Image Labeling
  Future<List<DetectedObject>> processImageFile(String filePath) async {
    if (!_isModelLoaded) await loadModel();
    if (!_isModelLoaded && !_isLabelerLoaded) return [];

    try {
      final File imageFile = File(filePath);
      final Uint8List imageBytes = await imageFile.readAsBytes();
      
      final codec = await instantiateImageCodec(imageBytes);
      final frameInfo = await codec.getNextFrame();
      final imageWidth = frameInfo.image.width.toDouble();
      final imageHeight = frameInfo.image.height.toDouble();

      final detections = <DetectedObject>[];
      final List<Map<String, dynamic>> mlLabels = [];

      // --- ML Kit Image Labeling ---
      img.Image? decodedImageForAnalysis;
      try {
        final inputImage = InputImage.fromFilePath(filePath);
        final labels = await _imageLabeler.processImage(inputImage);
        
        for (final label in labels) {
          final text = label.label.toLowerCase();
          mlLabels.add({'text': text, 'label': label.label, 'confidence': label.confidence});
          
          // Stair detection with step count estimation
          if (text.contains('stair') || text.contains('step') || text.contains('staircase')) {
            // Decode image for step counting if not already decoded
            if (decodedImageForAnalysis == null) {
              decodedImageForAnalysis = img.decodeImage(imageBytes);
            }
            
            int estimatedSteps = 0;
            if (decodedImageForAnalysis != null) {
              estimatedSteps = _estimateStairStepCount(decodedImageForAnalysis!);
            }
            
            detections.add(DetectedObject(
              label: 'Staircase',
              confidence: label.confidence,
              left: 0.1, 
              top: 0.1,
              width: 0.8,
              height: 0.8,
              distanceMeters: 2.0,
              stepCount: estimatedSteps,
            ));
          }
          
          // Door detection with open/close status
          if (text.contains('door')) {
            bool isOpen = text.contains('open') || 
                          mlLabels.any((l) => (l['text'] as String).contains('open'));
            bool isClosed = text.contains('close') || text.contains('closed') ||
                           mlLabels.any((l) => (l['text'] as String).contains('close'));
            
            String doorLabel = isOpen ? 'Open Door' : (isClosed ? 'Closed Door' : 'Door');
            
            detections.add(DetectedObject(
              label: doorLabel,
              confidence: label.confidence,
              left: 0.1, 
              top: 0.1,
              width: 0.8,
              height: 0.8,
              distanceMeters: 2.5,
              isDoorOpen: isOpen,
            ));
          }
          
          // Glasses detection
          if (text.contains('glasses') || 
              text.contains('sunglasses') || 
              text.contains('spectacles')) {
            
            detections.add(DetectedObject(
              label: label.label,
              confidence: label.confidence,
              left: 0.1, 
              top: 0.1,
              width: 0.8,
              height: 0.8,
              distanceMeters: 2.0,
              stepCount: 0,
            ));
          }

          // Sign and Board detection for OCR triggering
          if (text.contains('sign') || 
              text.contains('billboard') || 
              text.contains('poster') || 
              text.contains('placard') ||
              text.contains('banner') ||
              text.contains('menu') || 
              text.contains('whiteboard') || 
              text.contains('blackboard')) {
            
            detections.add(DetectedObject(
              label: 'Sign board (${label.label})', // Ensures main.dart detects "sign" keyword
              confidence: label.confidence,
              left: 0.1, 
              top: 0.1,
              width: 0.8,
              height: 0.8,
              distanceMeters: 2.0,
              stepCount: 0,
            ));
          }
        }
      } catch (e) {
        print("ML Kit Labeling error: $e");
      }

      // --- YOLOv8 Inference ---
      if (_isModelLoaded) {
        final results = await _vision.yoloOnImage(
          bytesList: imageBytes,
          imageHeight: frameInfo.image.height,
          imageWidth: frameInfo.image.width,
          iouThreshold: 0.4,
          confThreshold: 0.4,
          classThreshold: 0.4,
        );
        
        img.Image? decodedImage;
        bool imageDecoded = false;

        for (final result in results) {
          final box = result["box"]; 
          if (box == null) continue;

          final double x1 = (box[0] as num).toDouble();
          final double y1 = (box[1] as num).toDouble();
          final double x2 = (box[2] as num).toDouble();
          final double y2 = (box[3] as num).toDouble();
          
          final width = x2 - x1;
          final height = y2 - y1;

          String label = result["tag"].toString();
          int detectedStepCount = 0;
          bool doorIsOpen = false;

          // Refine 'door' label - detect if open or closed using image analysis
          if (label.toLowerCase() == 'door') {
            if (!imageDecoded) {
              decodedImage = img.decodeImage(imageBytes);
              imageDecoded = true;
            }
            if (decodedImage != null) {
              doorIsOpen = _analyzeDoorState(decodedImage!, x1, y1, width, height);
              label = doorIsOpen ? "Open Door" : "Closed Door";
            } else {
              // Fallback to ML Kit labels
              for (var ml in mlLabels) {
                String t = ml['text'] as String;
                if (t.contains('door')) {
                  if (t.contains('open')) {
                    label = "Open Door";
                    doorIsOpen = true;
                    break;
                  } else if (t.contains('close')) {
                    label = "Closed Door";
                    break;
                  }
                }
              }
            }
          }
          
          // Detect stairs and estimate step count
          if (label.toLowerCase().contains('stair') || 
              mlLabels.any((l) => (l['text'] as String).contains('stair'))) {
            if (!imageDecoded) {
              decodedImage = img.decodeImage(imageBytes);
              imageDecoded = true;
            }
            if (decodedImage != null) {
              detectedStepCount = _estimateStairStepCount(decodedImage!, x: x1.toInt(), y: y1.toInt(), w: width.toInt(), h: height.toInt());
            }
            label = "Staircase";
          }

          // Traffic Light Color Detection
          if (label == 'traffic light') {
            if (!imageDecoded) {
              decodedImage = img.decodeImage(imageBytes);
              imageDecoded = true;
            }
            if (decodedImage != null) {
              final color = _detectTrafficLightColor(decodedImage, x1, y1, width, height);
              if (color != null) {
                label = '$color Traffic Light';
              }
            }
          }
          // General Color Detection (excluding 'person' and 'chair')
          else if (label != 'person' && label != 'chair') {
             if (!imageDecoded) {
              decodedImage = img.decodeImage(imageBytes);
              imageDecoded = true;
            }
            if (decodedImage != null) {
              final color = _detectObjectColor(decodedImage, x1, y1, width, height);
              if (color != null) {
                // Prepend color to label, e.g., "Red Car"
                label = "$color $label"; 
              }
            }
          }
          
          double confidence = 0.5;
          if (box is List && box.length > 4) {
            confidence = (box[4] as num).toDouble();
          } else if (result.containsKey("conf")) {
             confidence = (result["conf"] as num).toDouble();
          }

          final normalizedLeft = x1 / imageWidth;
          final normalizedTop = y1 / imageHeight;
          final normalizedWidth = width / imageWidth;
          final normalizedHeight = height / imageHeight;

          if (normalizedWidth <= 0 || normalizedHeight <= 0) continue;

          detections.add(DetectedObject(
            label: label,
            confidence: confidence,
            left: normalizedLeft.clamp(0.0, 1.0),
            top: normalizedTop.clamp(0.0, 1.0),
            width: normalizedWidth.clamp(0.0, 1.0),
            height: normalizedHeight.clamp(0.0, 1.0),
            distanceMeters: _estimateDistance(normalizedHeight, imageHeight, label),
            stepCount: detectedStepCount,
            isDoorOpen: doorIsOpen,
          ));
        }
      }

      detections.sort((a, b) => b.confidence.compareTo(a.confidence));
      return detections;
    } catch (e) {
      print('Detection error: $e');
      return [];
    }
  }

  String? _detectTrafficLightColor(img.Image image, double x, double y, double w, double h) {
    try {
      int ix = x.toInt().clamp(0, image.width - 1);
      int iy = y.toInt().clamp(0, image.height - 1);
      int iw = w.toInt().clamp(1, image.width - ix);
      int ih = h.toInt().clamp(1, image.height - iy);

      final crop = img.copyCrop(image, x: ix, y: iy, width: iw, height: ih);

      int redScore = 0;
      int greenScore = 0;
      int yellowScore = 0;

      for (final pixel in crop) {
        num r = pixel.r;
        num g = pixel.g;
        num b = pixel.b;

        // Boost brightness check to ignore dark/off lights
        if (r < 100 && g < 100 && b < 100) continue;

        // Check for Yellow first (High Red AND High Green)
        // Traffic yellow/amber is often R=255, G=180-220
        if (r > 150 && g > 120 && b < 140) {
          yellowScore++;
        } 
        // Then Red (High Red, Low Green)
        else if (r > g + 50 && r > b + 50) { 
          redScore++;
        } 
        // Then Green
        else if (g > r + 20 && g > b + 20) {
          greenScore++;
        }
      }

      if (redScore > greenScore && redScore > yellowScore && redScore > 5) return "Red";
      if (greenScore > redScore && greenScore > yellowScore && greenScore > 5) return "Green";
      if (yellowScore > redScore && yellowScore > greenScore && yellowScore > 5) return "Yellow";

      return null;
    } catch (e) {
      print("Error detecting traffic light color: $e");
      return null;
    }
  }

  /// Detects the dominant color of an object
  String? _detectObjectColor(img.Image image, double x, double y, double w, double h) {
    try {
      int ix = x.toInt().clamp(0, image.width - 1);
      int iy = y.toInt().clamp(0, image.height - 1);
      int iw = w.toInt().clamp(1, image.width - ix);
      int ih = h.toInt().clamp(1, image.height - iy);

      // Analyze the center 50% of the object to avoid background
      int cx = (ix + iw * 0.25).toInt();
      int cy = (iy + ih * 0.25).toInt();
      int cw = (iw * 0.5).toInt();
      int ch = (ih * 0.5).toInt();
      
      final crop = img.copyCrop(image, x: cx, y: cy, width: cw, height: ch);

      Map<String, int> colorCounts = {
        'Red': 0, 'Orange': 0, 'Yellow': 0, 'Green': 0, 'Blue': 0, 
        'Purple': 0, 'Pink': 0, 'White': 0, 'Gray': 0, 'Black': 0, 'Brown': 0
      };

      for (final pixel in crop) {
        int r = pixel.r.toInt();
        int g = pixel.g.toInt();
        int b = pixel.b.toInt();

        String color = _classifyColor(r, g, b);
        colorCounts[color] = (colorCounts[color] ?? 0) + 1;
      }

      // Find dominant color
      String dominant = "";
      int maxCount = 0;
      int totalPixels = crop.width * crop.height;

      colorCounts.forEach((color, count) {
        if (count > maxCount) {
          maxCount = count;
          dominant = color;
        }
      });

      // Threshold: Dominant color must be at least 15% of the sampled area to be confident
      if (maxCount > totalPixels * 0.15) {
        return dominant;
      }
      return null;
      
    } catch (e) {
      return null;
    }
  }

  String _classifyColor(int r, int g, int b) {
    // Simple RGB-to-Color logic
    // A more accurate way would be HSL conversion, but this is fast for real-time
    
    // Grayscale check
    int max = [r, g, b].reduce((curr, next) => curr > next ? curr : next);
    int min = [r, g, b].reduce((curr, next) => curr < next ? curr : next);
    int range = max - min;

    if (range < 20) {
      if (max > 200) return 'White';
      if (max < 50) return 'Black';
      return 'Gray';
    }

    // Hue-ish logic
    if (r > 200 && g > 200 && b < 100) return 'Yellow'; // Bright Yellow
    if (r > 150 && g > 150 && b < 100) return 'Yellow'; // Dimmer Yellow
    
    if (r > g && r > b) {
      if (g > b && r < g + 50) return 'Orange';
      if (g < 50 && b < 50) return 'Red';
      if (b > 100) return 'Pink'; // Red+Blue ish
      if (g > 100) return 'Orange';
      return 'Red';
    }
    
    if (g > r && g > b) {
       if (r > b && g < r + 50) return 'Yellow'; // Greenish-Yellow
       return 'Green';
    }
    
    if (b > r && b > g) {
      if (r > g && b < r + 50) return 'Purple';
      return 'Blue';
    }
    
    if (r > 100 && g < 50 && b < 50) return 'Brown';
    
    return 'Gray'; // Fallback
  }

  Future<List<DetectedObject>> processFrame(CameraImage image, int sensorOrientation) async {
    return [];
  }

  double _estimateDistance(double normalizedHeight, double imageHeight, String label) {
    final knownHeight = _knownHeightMap[label.toLowerCase()] ?? 0.5;
    final pixelHeight = normalizedHeight * imageHeight;
    
    if (pixelHeight <= 0) return 5.0;
    
    final rawDistance = (knownHeight * _focalLength) / pixelHeight;
    final clampedDistance = rawDistance.clamp(0.3, 20.0);
    
    return _getSmoothedDistance(label, clampedDistance);
  }

  double _getSmoothedDistance(String label, double newReading) {
    if (!_distanceHistory.containsKey(label)) {
      _distanceHistory[label] = [];
    }
    final history = _distanceHistory[label]!;
    history.add(newReading);
    if (history.length > _historySize) history.removeAt(0);
    return history.reduce((a, b) => a + b) / history.length;
  }

  /// Estimate the number of steps in a staircase using edge detection
  /// Analyzes horizontal lines in the image to count steps
  int _estimateStairStepCount(img.Image image, {int? x, int? y, int? w, int? h}) {
    try {
      // Crop to the region of interest if coordinates provided
      img.Image regionImage;
      if (x != null && y != null && w != null && h != null) {
        int ix = x.clamp(0, image.width - 1);
        int iy = y.clamp(0, image.height - 1);
        int iw = w.clamp(1, image.width - ix);
        int ih = h.clamp(1, image.height - iy);
        regionImage = img.copyCrop(image, x: ix, y: iy, width: iw, height: ih);
      } else {
        // Use center portion of image for stair detection
        int cropX = (image.width * 0.2).toInt();
        int cropY = (image.height * 0.3).toInt();
        int cropW = (image.width * 0.6).toInt();
        int cropH = (image.height * 0.5).toInt();
        regionImage = img.copyCrop(image, x: cropX, y: cropY, width: cropW, height: cropH);
      }

      // Convert to grayscale and apply edge detection
      final grayscale = img.grayscale(regionImage);
      final edges = img.sobel(grayscale);

      // Count horizontal edge transitions (steps appear as horizontal lines)
      int stepCount = 0;
      int lastEdgeY = -10; // Minimum distance between detected steps
      final minStepGap = (regionImage.height / 20).round().clamp(3, 15);

      // Scan vertically through the image
      for (int scanY = 0; scanY < edges.height; scanY++) {
        int edgePixelCount = 0;
        
        // Count strong horizontal edge pixels in this row
        for (int scanX = 0; scanX < edges.width; scanX++) {
          final pixel = edges.getPixel(scanX, scanY);
          final intensity = pixel.r.toInt(); // Grayscale, so r=g=b
          
          // Strong horizontal edge detected
          if (intensity > 100) {
            edgePixelCount++;
          }
        }
        
        // If more than 30% of the row has edge pixels, likely a step edge
        if (edgePixelCount > edges.width * 0.3) {
          if (scanY - lastEdgeY > minStepGap) {
            stepCount++;
            lastEdgeY = scanY;
          }
        }
      }

      // Reasonable bounds for step count (typically 3-20 steps)
      return stepCount.clamp(0, 25);
    } catch (e) {
      print('Error estimating step count: $e');
      return 0;
    }
  }

  /// Analyze if a door is open or closed based on image analysis
  /// Looks for dark void (open door) vs solid surface (closed door)
  bool _analyzeDoorState(img.Image image, double x, double y, double w, double h) {
    try {
      int ix = x.toInt().clamp(0, image.width - 1);
      int iy = y.toInt().clamp(0, image.height - 1);
      int iw = w.toInt().clamp(1, image.width - ix);
      int ih = h.toInt().clamp(1, image.height - iy);

      final doorRegion = img.copyCrop(image, x: ix, y: iy, width: iw, height: ih);
      
      // Analyze the center of the door region
      int centerX = (doorRegion.width * 0.3).toInt();
      int centerY = (doorRegion.height * 0.3).toInt();
      int analyzeW = (doorRegion.width * 0.4).toInt();
      int analyzeH = (doorRegion.height * 0.4).toInt();
      
      final centerRegion = img.copyCrop(doorRegion, 
          x: centerX, y: centerY, width: analyzeW.clamp(1, doorRegion.width), height: analyzeH.clamp(1, doorRegion.height));

      // Calculate average brightness and variance
      double totalBrightness = 0;
      int darkPixels = 0;
      int totalPixels = 0;

      for (final pixel in centerRegion) {
        num r = pixel.r;
        num g = pixel.g;
        num b = pixel.b;
        double brightness = (r + g + b) / 3;
        totalBrightness += brightness;
        totalPixels++;
        
        // Count very dark pixels (potential opening/void)
        if (brightness < 50) {
          darkPixels++;
        }
      }

      if (totalPixels == 0) return false;

      double avgBrightness = totalBrightness / totalPixels;
      double darkRatio = darkPixels / totalPixels;

      // Open door indicators:
      // 1. Large dark void in center (looking through doorway)
      // 2. Very low average brightness in door region
      // 3. High ratio of dark pixels
      
      // Door is likely OPEN if:
      // - More than 40% dark pixels (seeing through to dark room/hallway)
      // - Or very low average brightness (< 60)
      bool isOpen = darkRatio > 0.4 || avgBrightness < 60;

      return isOpen;
    } catch (e) {
      print('Error analyzing door state: $e');
      return false; // Default to closed if analysis fails
    }
  }

  bool get isModelLoaded => _isModelLoaded;

  void dispose() {
    _vision.closeYoloModel();
  }
}
