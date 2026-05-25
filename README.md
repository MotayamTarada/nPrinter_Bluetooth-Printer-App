
دليل إجراءات للمبرمج الثاني (جزئية شاشة البحث/الصلاحيات)

افهم نقطة الدخول أولًا:
شاشة البحث تُفتح من: bluetooth_printer_home_page.dart (line 861)
الشاشة نفسها (UI واحد للمنصتين): bluetooth_devices_scan_page.dart (line 12)
افهم التفرع حسب المنصة داخل نفس الشاشة:
فرع iOS يبدأ هنا: bluetooth_devices_scan_page.dart (line 216)
فرع Android يبدأ هنا: bluetooth_devices_scan_page.dart (line 231)
الاقتران داخل التطبيق Android فقط: bluetooth_devices_scan_page.dart (line 374)
تحقق من صلاحيات iOS (قبل أي تعديل):
بوابة صلاحيات iOS: main.dart (line 125)
شاشة البوابة: ios_bluetooth_permission_page.dart (line 5)
منطق تقييم الصلاحية/حالة البلوتوث: ios_bluetooth_permission_gate_service.dart (line 31)
مسح BLE وطلب الصلاحية: ios_ble_printer_service.dart (line 115)
Native warmup (CoreBluetooth): AppDelegate.swift (line 15)
مفاتيح الصلاحيات: Info.plist (line 30)
permission_handler macros: Podfile (line 101)
قواعد تعديل آمنة:
إذا المطلوب “تعديل شكل/ترتيب الشاشة”: عدّل فقط bluetooth_devices_scan_page.dart.
إذا المطلوب “سلوك الصلاحيات في iPhone”: عدّل فقط ملفات iOS gate/service المذكورة فوق.
لا تخلط بين سلوك Android pairing وسلوك iOS BLE إلا إذا التغيير مطلوب صراحة.
سيناريو اختبار إلزامي بعد أي تعديل:
iOS (أول تثبيت): تظهر شاشة الصلاحية ثم تنتقل للتطبيق عند السماح.
iOS (رفض الصلاحية): يبقى المستخدم في شاشة الصلاحية مع زر Settings.
Android: البحث يعرض paired + nearby، والاقتران من داخل التطبيق يعمل.
المنصتان: نفس ترتيب الواجهة في شاشة البحث (UI ثابت) مع اختلاف السلوك فقط.
معيار القبول النهائي:
نفس UI بين Android/iOS.
صلاحيات iOS تعمل بدون تعليق.
لا regression في Android discovery/pairing.
الطباعة تظل تعمل عبر مسار المنصة الصحيح في bluetooth_printer_service.dart (line 26).
