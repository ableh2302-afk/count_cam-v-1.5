import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

final AppSettings appSettings = AppSettings();

class AppSettings extends ChangeNotifier {
  late SharedPreferences _p;
  double ringWidth = 3, textSize = 14, strokeWidth = 5;
  double tolerance = 6, param1 = 100, param2 = 30, minDistFactor = 1.6;
  bool showNumbers = true, autoTorch = false, haptic = true, watermark = true;
  int refSizeIdx = 5;
  int camQuality = 0; // 0 = Standar (1080p), 1 = Tinggi (4K), 2 = Cepat (720p)
  bool showGrid = true;
  // Gaya penanda: 0 bulat penuh, 1 kotak penuh, 2 cincin, 3 bulat+nomor, 4 kotak+nomor, 5 cincin+nomor
  int markStyle = 5;
  // Warna: -1 = per ukuran pipa, -2 = berganti (hijau/merah/biru), selain itu = nilai ARGB
  int markColorMode = -1;
  double labelOpacity = 1.0, maskOpacity = 0.25, roundness = 0.5;
  bool filterOutliers = false;
  double sheetLineW = 1.0; // ketebalan garis penanda lembaran
  double sheetSens = 1.0, sheetMark = 1.0, sheetBw = 12; // sensitivitas default, ukuran lingkaran, lebar jalur hitung (% lebar foto)
  bool sheetNum = true, sheetZig = true, sheetFillG = true, sheetFillO = false; // nomor, zigzag, isi garis samar (gypsum / triplek-GRC)
  int sheetBands = 5; // jumlah jalur mode otomatis
  List<int> sheetColors = [0xFFE53935, 0xFF1E88E5, 0xFFD81B60]; // warna per material: gypsum, triplek, GRC
  int homeMat = 0, homeThick = -1; // template beranda: 0 = pipa, 1.. = lembaran (indeks kSheetTemplates + 1)
  bool autoComplete = true, smallPipe = false, autoOnlyLargest = true; // lengkapi pipa terlewat; mode pipa kecil (1/2", 3/4") resolusi tinggi
  bool uniformRadius = true; // semua lingkaran hasil scan = ukuran lingkaran yang di-TAP
  List<int> colors = List.of(kDefaultColors);

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    ringWidth = _p.getDouble('ringWidth') ?? 3;
    textSize = _p.getDouble('textSize') ?? 14;
    strokeWidth = _p.getDouble('strokeWidth') ?? 5;
    tolerance = _p.getDouble('tolerance') ?? 6;
    param1 = _p.getDouble('param1') ?? 100;
    param2 = _p.getDouble('param2') ?? 30;
    minDistFactor = _p.getDouble('minDistFactor') ?? 1.6;
    showNumbers = _p.getBool('showNumbers') ?? true;
    autoTorch = _p.getBool('autoTorch') ?? false;
    haptic = _p.getBool('haptic') ?? true;
    watermark = _p.getBool('watermark') ?? true;
    refSizeIdx = _p.getInt('refSizeIdx') ?? 5;
    camQuality = _p.getInt('camQuality') ?? 0;
    showGrid = _p.getBool('showGrid') ?? true;
    markStyle = _p.getInt('markStyle') ?? 5;
    markColorMode = _p.getInt('markColorMode') ?? -1;
    labelOpacity = _p.getDouble('labelOpacity') ?? 1.0;
    maskOpacity = _p.getDouble('maskOpacity') ?? 0.25;
    roundness = _p.getDouble('roundness') ?? 0.5;
    filterOutliers = _p.getBool('filterOutliers') ?? false;
    uniformRadius = _p.getBool('uniformRadius') ?? true;
    autoComplete = _p.getBool('autoComplete') ?? true;
    smallPipe = _p.getBool('smallPipe') ?? false;
    autoOnlyLargest = _p.getBool('autoOnlyLargest') ?? true;
    homeMat = _p.getInt('homeMat') ?? 0;
    homeThick = _p.getInt('homeThick') ?? -1;
    sheetLineW = _p.getDouble('sheetLineW') ?? 1.0;
    sheetSens = _p.getDouble('sheetSens') ?? 1.0;
    sheetMark = _p.getDouble('sheetMark') ?? 1.0;
    sheetBw = _p.getDouble('sheetBw') ?? 12;
    sheetNum = _p.getBool('sheetNum') ?? true;
    sheetZig = _p.getBool('sheetZig') ?? true;
    sheetFillG = _p.getBool('sheetFillG') ?? true;
    sheetFillO = _p.getBool('sheetFillO') ?? false;
    sheetBands = _p.getInt('sheetBands') ?? 5;
    final sc = _p.getStringList('sheetColors');
    if (sc != null && sc.length == 3) sheetColors = sc.map(int.parse).toList();
    final c = _p.getStringList('colors');
    if (c != null && c.length == kPipeSizes.length) colors = c.map(int.parse).toList();
  }

  Future<void> save() async {
    await _p.setDouble('ringWidth', ringWidth);
    await _p.setDouble('textSize', textSize);
    await _p.setDouble('strokeWidth', strokeWidth);
    await _p.setDouble('tolerance', tolerance);
    await _p.setDouble('param1', param1);
    await _p.setDouble('param2', param2);
    await _p.setDouble('minDistFactor', minDistFactor);
    await _p.setBool('showNumbers', showNumbers);
    await _p.setBool('autoTorch', autoTorch);
    await _p.setBool('haptic', haptic);
    await _p.setBool('watermark', watermark);
    await _p.setInt('refSizeIdx', refSizeIdx);
    await _p.setInt('camQuality', camQuality);
    await _p.setBool('showGrid', showGrid);
    await _p.setInt('markStyle', markStyle);
    await _p.setInt('markColorMode', markColorMode);
    await _p.setDouble('labelOpacity', labelOpacity);
    await _p.setDouble('maskOpacity', maskOpacity);
    await _p.setDouble('roundness', roundness);
    await _p.setBool('filterOutliers', filterOutliers);
    await _p.setBool('uniformRadius', uniformRadius);
    await _p.setBool('autoComplete', autoComplete);
    await _p.setBool('smallPipe', smallPipe);
    await _p.setBool('autoOnlyLargest', autoOnlyLargest);
    await _p.setInt('homeMat', homeMat);
    await _p.setInt('homeThick', homeThick);
    await _p.setDouble('sheetLineW', sheetLineW);
    await _p.setDouble('sheetSens', sheetSens);
    await _p.setDouble('sheetMark', sheetMark);
    await _p.setDouble('sheetBw', sheetBw);
    await _p.setBool('sheetNum', sheetNum);
    await _p.setBool('sheetZig', sheetZig);
    await _p.setBool('sheetFillG', sheetFillG);
    await _p.setBool('sheetFillO', sheetFillO);
    await _p.setInt('sheetBands', sheetBands);
    await _p.setStringList('sheetColors', sheetColors.map((e) => e.toString()).toList());
    await _p.setStringList('colors', colors.map((e) => e.toString()).toList());
    notifyListeners();
  }

  Color colorOf(int i) => Color(colors[i]);

  static const List<int> multiColors = [0xFF22C55E, 0xFFEF4444, 0xFF2563EB];

  /// Warna penanda ke-[order] untuk ukuran [sizeIdx] sesuai mode warna.
  Color markColor(int sizeIdx, int order) {
    if (markColorMode == -1) return colorOf(sizeIdx);
    if (markColorMode == -2) return Color(multiColors[order % multiColors.length]);
    return Color(markColorMode);
  }

  void resetMarkStyle() {
    markStyle = 5;
    markColorMode = -1;
    labelOpacity = 1.0;
    maskOpacity = 0.25;
    roundness = 0.5;
    ringWidth = 3;
    textSize = 14;
    showNumbers = true;
    filterOutliers = false;
  }
}
