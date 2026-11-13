"""Egypt's governorates and reference towns for the schools import (F4).

OpenStreetMap points rarely carry their governorate. When no boundaries
file is given (see SETUP.md, "Schools list"), each school gets the
governorate of the NEAREST reference town below. That is right almost
everywhere but can be wrong within a few kilometres of a border (for
example Shubra in Cairo next to Shubra El Kheima in Qalyubia); the report
counts how many schools were placed this way so the owner can add the
boundaries file for an exact answer.

Coordinates are approximate town centres (about 1 km), good enough for
"nearest town" and for the city shown under a school's name.

Governorate codes are the same 27 codes as functions/src/admin_panel/schools.ts
and kGovernorates in lib/admin/data/admin_models.dart.
"""

from __future__ import annotations

GOVERNORATES: tuple[str, ...] = (
    "alexandria", "aswan", "asyut", "beheira", "beni_suef", "cairo", "dakahlia",
    "damietta", "faiyum", "gharbia", "giza", "ismailia", "kafr_el_sheikh", "luxor",
    "matruh", "minya", "monufia", "new_valley", "north_sinai", "port_said",
    "qalyubia", "qena", "red_sea", "sharqia", "sohag", "south_sinai", "suez",
)

# Names people and files use for each governorate (Arabic and Latin
# spellings). Matched after normalize_text, so hamza, taa marbuta and
# "al-"/"el-" differences do not matter.
GOVERNORATE_ALIASES: dict[str, tuple[str, ...]] = {
    "alexandria": ("الإسكندرية", "الاسكندرية", "اسكندرية", "Alexandria", "Alex", "Iskandariya"),
    "aswan": ("أسوان", "Aswan"),
    "asyut": ("أسيوط", "Asyut", "Assiut", "Assuit", "Asiut"),
    "beheira": ("البحيرة", "Beheira", "Behera", "Buhayrah", "El Beheira"),
    "beni_suef": ("بني سويف", "Beni Suef", "Beni Sweif", "Bani Suwayf"),
    "cairo": ("القاهرة", "Cairo", "Al Qahirah"),
    "dakahlia": ("الدقهلية", "Dakahlia", "Dakahleya", "Daqahliyah", "Dakhalia"),
    "damietta": ("دمياط", "Damietta", "Dumyat"),
    "faiyum": ("الفيوم", "Faiyum", "Fayoum", "Fayyum", "Fayum"),
    "gharbia": ("الغربية", "Gharbia", "Gharbeya", "Gharbiyah"),
    "giza": ("الجيزة", "Giza", "Gizah", "Al Jizah"),
    "ismailia": ("الإسماعيلية", "Ismailia", "Ismailiya", "Ismailiyah"),
    "kafr_el_sheikh": ("كفر الشيخ", "Kafr El Sheikh", "Kafr el-Sheikh", "Kafr Ash Shaykh"),
    "luxor": ("الأقصر", "Luxor", "Al Uqsur"),
    "matruh": ("مطروح", "Matruh", "Matrouh", "Marsa Matruh", "Mersa Matruh"),
    "minya": ("المنيا", "Minya", "Menia", "Al Minya", "Minia"),
    "monufia": ("المنوفية", "Monufia", "Menoufia", "Minufiyah", "Menofia"),
    "new_valley": ("الوادي الجديد", "New Valley", "Al Wadi al Jadid"),
    "north_sinai": ("شمال سيناء", "North Sinai", "Shamal Sina"),
    "port_said": ("بورسعيد", "بور سعيد", "Port Said", "Bur Said"),
    "qalyubia": ("القليوبية", "Qalyubia", "Qaliubiya", "Kalyubia", "Qalyubiyah"),
    "qena": ("قنا", "Qena", "Qina", "Kena"),
    "red_sea": ("البحر الأحمر", "Red Sea", "Al Bahr al Ahmar"),
    "sharqia": ("الشرقية", "Sharqia", "Sharkia", "Sharqiyah", "Al Sharqia"),
    "sohag": ("سوهاج", "Sohag", "Suhag", "Suhaj"),
    "south_sinai": ("جنوب سيناء", "South Sinai", "Janub Sina"),
    "suez": ("السويس", "Suez", "As Suways"),
}

# (governorate, English name, Arabic name, lat, lng)
TOWNS: tuple[tuple[str, str, str, float, float], ...] = (
    # Cairo
    ("cairo", "Downtown Cairo", "وسط القاهرة", 30.0444, 31.2357),
    ("cairo", "Zamalek", "الزمالك", 30.0609, 31.2197),
    ("cairo", "Nasr City", "مدينة نصر", 30.0566, 31.3301),
    ("cairo", "Heliopolis", "مصر الجديدة", 30.0911, 31.3220),
    ("cairo", "Maadi", "المعادي", 29.9602, 31.2569),
    ("cairo", "New Cairo", "القاهرة الجديدة", 30.0300, 31.4700),
    ("cairo", "Rehab", "الرحاب", 30.0600, 31.4900),
    ("cairo", "Madinaty", "مدينتي", 30.1070, 31.6380),
    ("cairo", "El Shorouk", "الشروق", 30.1300, 31.6200),
    ("cairo", "Badr City", "مدينة بدر", 30.1350, 31.7150),
    ("cairo", "New Administrative Capital", "العاصمة الإدارية", 30.0200, 31.7600),
    ("cairo", "Shubra", "شبرا", 30.0820, 31.2450),
    ("cairo", "Ain Shams", "عين شمس", 30.1310, 31.3290),
    ("cairo", "El Salam City", "مدينة السلام", 30.1700, 31.4200),
    ("cairo", "Mokattam", "المقطم", 30.0200, 31.3000),
    ("cairo", "Helwan", "حلوان", 29.8414, 31.3008),
    ("cairo", "15th of May City", "مدينة 15 مايو", 29.8500, 31.3800),
    # Giza
    ("giza", "Giza", "الجيزة", 30.0131, 31.2089),
    ("giza", "Dokki", "الدقي", 30.0384, 31.2120),
    ("giza", "Mohandessin", "المهندسين", 30.0560, 31.2000),
    ("giza", "Imbaba", "إمبابة", 30.0760, 31.2090),
    ("giza", "Haram", "الهرم", 29.9930, 31.1500),
    ("giza", "6th of October City", "مدينة السادس من أكتوبر", 29.9727, 30.9430),
    ("giza", "Sheikh Zayed City", "مدينة الشيخ زايد", 30.0200, 30.9800),
    ("giza", "Hadayek October", "حدائق أكتوبر", 29.9200, 30.9000),
    ("giza", "Kerdasa", "كرداسة", 30.0300, 31.1100),
    ("giza", "Hawamdeya", "الحوامدية", 29.9000, 31.2500),
    ("giza", "Badrashin", "البدرشين", 29.8500, 31.2700),
    ("giza", "Al Ayyat", "العياط", 29.6200, 31.2600),
    ("giza", "Atfih", "أطفيح", 29.4100, 31.2500),
    # Qalyubia
    ("qalyubia", "Banha", "بنها", 30.4660, 31.1858),
    ("qalyubia", "Shubra El Kheima", "شبرا الخيمة", 30.1286, 31.2422),
    ("qalyubia", "Qalyub", "قليوب", 30.1800, 31.2100),
    ("qalyubia", "Obour City", "مدينة العبور", 30.2280, 31.4790),
    ("qalyubia", "Khanka", "الخانكة", 30.2100, 31.3700),
    ("qalyubia", "Shibin El Qanater", "شبين القناطر", 30.3100, 31.3200),
    ("qalyubia", "Tukh", "طوخ", 30.3500, 31.2000),
    ("qalyubia", "Kafr Shukr", "كفر شكر", 30.5500, 31.2700),
    # Alexandria
    ("alexandria", "Alexandria", "الإسكندرية", 31.2001, 29.9187),
    ("alexandria", "Smouha", "سموحة", 31.2150, 29.9450),
    ("alexandria", "Montaza", "المنتزه", 31.2800, 30.0100),
    ("alexandria", "Agami", "العجمي", 31.1000, 29.7700),
    ("alexandria", "Amreya", "العامرية", 31.0300, 29.8000),
    ("alexandria", "Borg El Arab", "برج العرب", 30.9000, 29.5800),
    # Beheira
    ("beheira", "Damanhur", "دمنهور", 31.0341, 30.4682),
    ("beheira", "Kafr El Dawwar", "كفر الدوار", 31.1300, 30.1300),
    ("beheira", "Rashid", "رشيد", 31.4000, 30.4200),
    ("beheira", "Edku", "إدكو", 31.3100, 30.3000),
    ("beheira", "Abu Hummus", "أبو حمص", 31.0900, 30.3100),
    ("beheira", "Kom Hamada", "كوم حمادة", 30.7600, 30.7000),
    ("beheira", "Wadi El Natrun", "وادي النطرون", 30.4300, 30.1700),
    ("beheira", "Nubaria", "النوبارية", 30.6700, 30.0700),
    # Matruh
    ("matruh", "Marsa Matruh", "مرسى مطروح", 31.3543, 27.2373),
    ("matruh", "El Alamein", "العلمين", 30.8300, 28.9500),
    ("matruh", "El Hammam", "الحمام", 30.8300, 29.3900),
    ("matruh", "El Dabaa", "الضبعة", 31.0300, 28.4300),
    ("matruh", "Siwa", "سيوة", 29.2000, 25.5200),
    ("matruh", "Sallum", "السلوم", 31.5500, 25.1500),
    # Kafr El Sheikh
    ("kafr_el_sheikh", "Kafr El Sheikh", "كفر الشيخ", 31.1107, 30.9388),
    ("kafr_el_sheikh", "Desouk", "دسوق", 31.1300, 30.6500),
    ("kafr_el_sheikh", "Baltim", "بلطيم", 31.5500, 31.0800),
    # Gharbia
    ("gharbia", "Tanta", "طنطا", 30.7865, 31.0004),
    ("gharbia", "El Mahalla El Kubra", "المحلة الكبرى", 30.9700, 31.1700),
    ("gharbia", "Kafr El Zayat", "كفر الزيات", 30.8200, 30.8100),
    ("gharbia", "Zefta", "زفتى", 30.7100, 31.2400),
    # Monufia
    ("monufia", "Shebin El Kom", "شبين الكوم", 30.5590, 31.0100),
    ("monufia", "Menouf", "منوف", 30.4600, 30.9300),
    ("monufia", "Sadat City", "مدينة السادات", 30.3600, 30.5300),
    ("monufia", "Ashmoun", "أشمون", 30.3000, 30.9800),
    ("monufia", "Quesna", "قويسنا", 30.5600, 31.1500),
    # Dakahlia
    ("dakahlia", "Mansoura", "المنصورة", 31.0409, 31.3785),
    ("dakahlia", "Mit Ghamr", "ميت غمر", 30.7200, 31.2600),
    ("dakahlia", "Belqas", "بلقاس", 31.2100, 31.3600),
    ("dakahlia", "Aga", "أجا", 30.9400, 31.2900),
    # Damietta
    ("damietta", "Damietta", "دمياط", 31.4165, 31.8133),
    ("damietta", "New Damietta", "دمياط الجديدة", 31.4400, 31.6800),
    ("damietta", "Faraskur", "فارسكور", 31.3300, 31.7100),
    # Sharqia
    ("sharqia", "Zagazig", "الزقازيق", 30.5877, 31.5020),
    ("sharqia", "10th of Ramadan City", "مدينة العاشر من رمضان", 30.3000, 31.7400),
    ("sharqia", "Belbeis", "بلبيس", 30.4200, 31.5600),
    ("sharqia", "Abu Hammad", "أبو حماد", 30.5300, 31.6700),
    ("sharqia", "Faqous", "فاقوس", 30.7300, 31.8000),
    ("sharqia", "Minya El Qamh", "منيا القمح", 30.5100, 31.3500),
    # Ismailia
    ("ismailia", "Ismailia", "الإسماعيلية", 30.5965, 32.2715),
    ("ismailia", "Fayed", "فايد", 30.3200, 32.3000),
    ("ismailia", "Qantara", "القنطرة", 30.8600, 32.3200),
    ("ismailia", "Tell El Kebir", "التل الكبير", 30.5500, 31.9800),
    # Port Said
    ("port_said", "Port Said", "بورسعيد", 31.2653, 32.3019),
    ("port_said", "Port Fouad", "بور فؤاد", 31.2500, 32.3200),
    # Suez
    ("suez", "Suez", "السويس", 29.9668, 32.5498),
    ("suez", "Ain Sokhna", "العين السخنة", 29.6000, 32.3200),
    # North Sinai
    ("north_sinai", "Arish", "العريش", 31.1316, 33.7984),
    ("north_sinai", "Sheikh Zuweid", "الشيخ زويد", 31.2100, 34.1100),
    ("north_sinai", "Bir al-Abd", "بئر العبد", 31.0200, 33.0100),
    # South Sinai
    ("south_sinai", "El Tor", "الطور", 28.2420, 33.6220),
    ("south_sinai", "Sharm El Sheikh", "شرم الشيخ", 27.9158, 34.3300),
    ("south_sinai", "Dahab", "دهب", 28.5000, 34.5100),
    ("south_sinai", "Nuweiba", "نويبع", 29.0300, 34.6600),
    ("south_sinai", "Saint Catherine", "سانت كاترين", 28.5600, 33.9500),
    ("south_sinai", "Ras Sudr", "رأس سدر", 29.5900, 32.7100),
    # Faiyum
    ("faiyum", "Faiyum", "الفيوم", 29.3084, 30.8428),
    ("faiyum", "Ibsheway", "إبشواي", 29.3600, 30.6800),
    ("faiyum", "Tamiya", "طامية", 29.4800, 30.9600),
    # Beni Suef
    ("beni_suef", "Beni Suef", "بني سويف", 29.0661, 31.0994),
    ("beni_suef", "El Wasta", "الواسطى", 29.3400, 31.2000),
    ("beni_suef", "Biba", "ببا", 28.9200, 30.9800),
    # Minya
    ("minya", "Minya", "المنيا", 28.0871, 30.7618),
    ("minya", "Mallawi", "ملوي", 27.7300, 30.8400),
    ("minya", "Samalut", "سمالوط", 28.3100, 30.7100),
    ("minya", "Maghagha", "مغاغة", 28.6500, 30.8400),
    ("minya", "Beni Mazar", "بني مزار", 28.5000, 30.8000),
    # Asyut
    ("asyut", "Asyut", "أسيوط", 27.1783, 31.1859),
    ("asyut", "Dairut", "ديروط", 27.5600, 30.8100),
    ("asyut", "Manfalut", "منفلوط", 27.3100, 30.9700),
    ("asyut", "Abnub", "أبنوب", 27.2700, 31.1500),
    # Sohag
    ("sohag", "Sohag", "سوهاج", 26.5591, 31.6948),
    ("sohag", "Akhmim", "أخميم", 26.5600, 31.7500),
    ("sohag", "Girga", "جرجا", 26.3400, 31.8900),
    ("sohag", "Tahta", "طهطا", 26.7700, 31.5000),
    # Qena
    ("qena", "Qena", "قنا", 26.1551, 32.7160),
    ("qena", "Nag Hammadi", "نجع حمادي", 26.0500, 32.2400),
    ("qena", "Qus", "قوص", 25.9100, 32.7600),
    # Luxor
    ("luxor", "Luxor", "الأقصر", 25.6872, 32.6396),
    ("luxor", "Esna", "إسنا", 25.2900, 32.5500),
    ("luxor", "Armant", "أرمنت", 25.6200, 32.5400),
    # Aswan
    ("aswan", "Aswan", "أسوان", 24.0889, 32.8998),
    ("aswan", "Kom Ombo", "كوم أمبو", 24.4700, 32.9500),
    ("aswan", "Edfu", "إدفو", 24.9800, 32.8800),
    ("aswan", "Abu Simbel", "أبو سمبل", 22.3400, 31.6300),
    # Red Sea
    ("red_sea", "Hurghada", "الغردقة", 27.2579, 33.8116),
    ("red_sea", "El Gouna", "الجونة", 27.3900, 33.6800),
    ("red_sea", "Safaga", "سفاجا", 26.7400, 33.9400),
    ("red_sea", "El Quseir", "القصير", 26.1000, 34.2800),
    ("red_sea", "Marsa Alam", "مرسى علم", 25.0700, 34.8900),
    ("red_sea", "Ras Gharib", "رأس غارب", 28.3600, 33.0800),
    # New Valley
    ("new_valley", "Kharga", "الخارجة", 25.4390, 30.5586),
    ("new_valley", "Dakhla", "الداخلة", 25.4900, 28.9800),
    ("new_valley", "Farafra", "الفرافرة", 27.0600, 27.9700),
    ("new_valley", "Baris", "باريس", 24.6700, 30.6000),
)

# A box around Egypt (same as EGYPT_BOUNDS in functions/src/admin_panel/schools.ts).
EGYPT_BOUNDS = {"min_lat": 21.5, "max_lat": 31.8, "min_lng": 24.5, "max_lng": 37.1}
