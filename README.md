# LiquidGlassDock

โปรเจกต์ Theos ที่สร้างจาก Deb Packer

1. สร้าง repository ใหม่บน github.com แล้วอัปโหลดไฟล์ทั้งหมดในโฟลเดอร์นี้
2. ไฟล์ .github/workflows/build.yml ต้องอยู่ในพาธนี้พอดี (สร้างด้วย Add file > Create new file แล้วพิมพ์พาธเต็ม)
3. เปิดแท็บ Actions รอ build เสร็จ แล้วดาวน์โหลด artifact ชื่อ deb
4. แตก zip จะได้ไฟล์ .deb สำหรับติดตั้งด้วย Sileo, Zebra หรือ Filza

## Liquid Glass Dock (ทดลอง)

- ดู log กรองคำว่า LGDock ควรเห็น ready, glass attached, captured
- Dock จะกะพริบหายประมาณ 0.1 วินาทีหลังรีสปริง 2.5 วินาที เพื่อจับภาพพื้นหลัง
- จับภาพใหม่: notifyutil -p com.example.liquidglassdock.recapture
- ปรับค่าที่ #define LG_* หัวไฟล์ Tweak.x
- ยังไม่ได้ตรวจบน iOS 16.7 จริง
