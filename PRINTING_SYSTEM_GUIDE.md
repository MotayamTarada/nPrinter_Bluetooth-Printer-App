# دليل نظام الطباعة المحسّن ESC/POS

## نظرة عامة

تم إصلاح وتحسين نظام الطباعة بالكامل لطابعة Bluetooth الحرارية ESC/POS من نوع nPrinter مع دعم الألوان الأسود/الأحمر.

## المميزات الرئيسية

### 1. مسارات طباعة منفصلة

#### أ. طباعة النصوص العادية
```dart
// طباعة نص بسيط - أسود فقط
await printBluetoothReceipt(
  context: context,
  text: 'مرحبا بك',
  mac: 'XX:XX:XX:XX:XX:XX',
  printColor: 'black',
);

// طباعة نص - أحمر فقط
await printBluetoothReceipt(
  context: context,
  text: 'تنبيه هام',
  mac: 'XX:XX:XX:XX:XX:XX',
  printColor: 'red',
);
```

#### ب. طباعة النصوص المختلطة (أسود + أحمر)
```dart
// استخدام PrintPart مع colors محددة
List<PrintPart> parts = [
  PrintPart('الفاتورة رقم: '),
  PrintPart('001', red: true),
  PrintPart('\nالسعر: '),
  PrintPart('100 ريال', red: true),
];

await printBluetoothReceipt(
  context: context,
  text: '',
  mac: 'XX:XX:XX:XX:XX:XX',
  parts: parts,
  printColor: 'black_red',
);
```

#### ج. طباعة PDF الأسود
```dart
// PDF بسيط - يطبع بالأسود فقط
await printBluetoothPdfReceipt(
  context: context,
  pdfPath: '/path/to/file.pdf',
  mac: 'XX:XX:XX:XX:XX:XX',
  printColor: 'black',
);
```

#### د. طباعة PDF الملون (أسود + أحمر)
```dart
// PDF ملون - يتم فصل الألوان تلقائياً
await printBluetoothPdfReceipt(
  context: context,
  pdfPath: '/path/to/colored.pdf',
  mac: 'XX:XX:XX:XX:XX:XX',
  printColor: 'black_red',
);
```

### 2. خدمة ESC/POS المتخصصة
```dart
import 'package:nprinter_bluetooth_only/services/esc_pos_printer_service.dart';

// فحص الاتصال
bool connected = await EscPosPrinterService.isPrinterConnected();

// طباعة نص بسيط
bool success = await EscPosPrinterService.printPlainText(
  text: 'مرحبا',
  mode: PrintColorMode.black,
);

// طباعة نصوص مختلطة
bool success = await EscPosPrinterService.printMixedText(
  parts: [
    PrintPart('أسود'),
    PrintPart('أحمر', red: true),
  ],
);

// اختبار الألوان
bool success = await EscPosPrinterService.printColorTest();
```

### 3. أوامر ESC/POS المستخدمة

#### التهيئة والألوان
```
[0x1B, 0x40]        -> Reset الطابعة
[0x1B, 0x72, 0x00]  -> اللون الأسود
[0x1B, 0x72, 0x01]  -> اللون الأحمر
[0x1B, 0x74, 92]    -> تعيين ترميز Windows-1256
[0x1B, 0x74, 28]    -> تعيين ترميز CP864
```

#### أوامر بديلة للأحمر
```
[0x1B, 0x63, 0x30, 0x01]  -> أمر بديل للأحمر (إذا فشل الأمر الأول)
```

#### الإطعام والقطع
```
[0x0A]              -> إطعام سطر واحد
[0x1D, 0x56, 0x00]  -> قطع الورق
```

### 4. ترميز النصوص العربية

```dart
// Windows-1256 (الافتراضي والموصى به)
EscPosTextEncoding.windows1256

// CP864
EscPosTextEncoding.cp864
```

## معالجة الأخطاء

### رسائل خطأ واضحة
- ✗ نص فارغ: "الرجاء إدخال نص للطباعة"
- ✗ عدم الاتصال: "الطابعة غير متصلة. تأكد من..."
- ✗ فشل الإرسال: "فشل إرسال جزء من النص للطابعة..."
- ✗ عدم دعم الأحمر: "الطابعة قد لا تدعم اللون الأحمر..."

### الحصول على رسالة خطأ مناسبة
```dart
String errorMsg = EscPosPrinterService.getErrorMessageForContext(
  context: 'not_connected',
  additionalInfo: 'تحقق من البطارية'
);
```

## إرسال البيانات بأمان

البيانات ترسل تلقائياً على دفعات صغيرة (chunks) مع تأخير آمن بين الأجزاء:

```
خيارات الإرسال:
- حجم الجزء الواحد: 128 byte (قابل للتخصيص)
- التأخير بين الأجزاء: 80 ms (قابل للتخصيص)
```

## اختبار الألوان

### اختبار بسيط
```dart
await printBluetoothColorTest(
  context: context,
  mac: 'XX:XX:XX:XX:XX:XX',
  textEncoding: EscPosTextEncoding.windows1256,
);
```

**النتيجة المتوقعة:**
```
BLACK TEST   <- أسود
RED TEST     <- أحمر
BLACK AGAIN  <- أسود
```

## شروط النجاح

✓ PDF الأسود يطبع بشكل صحيح
✓ النصوص العادية لا تعتمد على استخراج من PDF
✓ خيار أسود يطبع النصوص كلها بالأسود
✓ خيار أحمر يطبع النصوص كلها بالأحمر
✓ خيار أسود + أحمر يطبع كل جزء حسب لونه
✓ اختبار الألوان يطبع بألوان صحيحة
✓ رسائل الأخطاء واضحة
✓ إرسال البيانات آمن عبر chunks

## الملفات المعدلة

1. **esc_pos_colored_text_service.dart**
   - إضافة `buildPlainTextEscPosBytes()`
   - إضافة `buildMixedTextEscPosBytes()`
   - تحسين `buildColorTestBytes()`

2. **esc_pos_printer_service.dart** (جديد)
   - خدمة متخصصة للطباعة
   - إدارة آمنة للإرسال
   - معالجة الأخطاء

3. **bluetooth_printer_service.dart**
   - تحسين `printBluetoothReceipt()`
   - إضافة `printPlainTextReceipt()`
   - إضافة `printMixedTextReceipt()`
   - تحسين رسائل الخطأ

4. **bluetooth_printer_home_page.dart**
   - إضافة استيراد الخدمة الجديدة

## ملاحظات مهمة

⚠️ **الطابعة ليست طابعة ألوان كاملة**
- تدعم الأسود والأحمر فقط
- الأحمر قد يكون للنصوص فقط على بعض الطرز
- استخدم ورق Black/Red مخصص

⚠️ **الترميز مهم جداً**
- استخدم windows-1256 للنصوص العربية
- اختبر التردد بين windows-1256 و cp864 إذا لزم الأمر

⚠️ **الإرسال يتم على chunks**
- لا تحاول إرسال بيانات ضخمة دفعة واحدة
- الحد الأقصى الآمن حوالي 128 byte لكل جزء

## أمثلة متقدمة

### فاتورة كاملة مع ألوان
```dart
List<PrintPart> invoice = [
  PrintPart('============\n'),
  PrintPart('الفاتورة رقم: '),
  PrintPart('INV-001\n', red: true),
  PrintPart('التاريخ: '),
  PrintPart('${DateTime.now()}\n', red: true),
  PrintPart('============\n'),
  PrintPart('السعر الإجمالي: '),
  PrintPart('500 ريال\n', red: true),
];

await printBluetoothReceipt(
  context: context,
  text: '',
  mac: printerMac,
  parts: invoice,
  printColor: 'black_red',
  autoCut: true,
  feedLines: 5,
);
```

## استكشاف الأخطاء

### المشكلة: النص الأحمر لا يطبع بالأحمر
**الحل:**
1. تحقق من أن الورق يدعم اللون الأحمر
2. حاول استخدام `useAlternativeRedCommand: true`
3. أرجع اللون للأسود قبل الطباعة التالية

### المشكلة: فشل الاتصال بشكل متكرر
**الحل:**
1. تأكد من اقتران الجهاز عبر Bluetooth
2. أعد تشغيل الطابعة
3. تحقق من صلاحيات Bluetooth

### المشكلة: النصوص العربية تظهر بشكل غير صحيح
**الحل:**
1. تأكد من استخدام `windows-1256` كترميز
2. جرب `cp864` إذا فشل الأول
3. تحقق من دعم الطابعة للعربية

## الدعم الفني

للمزيد من المعلومات عن ESC/POS:
- https://en.wikipedia.org/wiki/ESC/P
- nPrinter Documentation
