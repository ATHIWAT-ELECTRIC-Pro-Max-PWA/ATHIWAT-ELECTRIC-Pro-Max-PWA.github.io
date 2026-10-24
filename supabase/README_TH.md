# ตั้งค่า Supabase สำหรับ ATHIWAT ELECTRIC Pro Max

โปรเจ็กต์นี้เตรียม Supabase Auth, ตารางสมาชิก, คลังข้อสอบ, ประวัติสอบ, โควตาฟรี, RLS และ RPC สำหรับโหลดข้อสอบ/ตรวจคำตอบ/บันทึกผล/จำกัดอุปกรณ์

## ติดตั้งฐานข้อมูลในโปรเจ็กต์ใหม่

1. เปิด Supabase Dashboard → SQL Editor
2. วางและ Run เนื้อหา `schema.sql`
3. วางและ Run `cloud-app-migration.sql` เพื่อเปิดฟังก์ชันให้บัญชีแรกที่เข้าสู่ระบบได้รับ role ผู้ดูแลคลังข้อสอบ
4. วางและ Run `billing-migration.sql` เพื่อเปิดวันหมดอายุ Pro Max และรับการยืนยันจาก webhook
5. ตั้ง URL และ Publishable key ใน `supabase-config.js` (ตัวอย่างอยู่ที่ `config.example.js`)
6. เผยแพร่โฟลเดอร์เว็บผ่าน HTTPS แล้วเปิดสมัครบัญชี

ในโปรเจ็กต์ `athiwat-electric-exam` ของผู้ใช้ schema และ migration ข้างต้นติดตั้งแล้ว แอปเชื่อมกับ URL และ Publishable key ของโปรเจ็กต์นี้เรียบร้อย

### แก้ปัญหา `permission denied for table questions`

หากสมาชิกเข้าสู่ระบบได้แต่หน้าเว็บแจ้งข้อผิดพลาดนี้ ให้รันคำสั่งใน `questions-permission-fix.sql` หนึ่งครั้งใน SQL Editor ของ Supabase เพื่อให้ RPC อ่านสถานะเผยแพร่ของข้อสอบได้ โดย RLS และสิทธิ์การเห็นข้อสอบตามแพ็กเกจยังทำงานเหมือนเดิม

## ความปลอดภัยและสิทธิ์

- ใช้ Publishable key ได้ในเว็บ ห้ามใช้ Secret/service-role key ในเบราว์เซอร์
- RLS จำกัดประวัติสอบและโควตาให้เป็นของบัญชีตัวเอง; คำตอบถูก/คำอธิบายถูกส่งกลับผ่าน RPC หลังตอบหรือส่งข้อสอบ
- ผู้ดูแลคลังเพิ่ม/ลบข้อสอบผ่าน RLS; สมาชิกทั่วไปอ่านได้เฉพาะข้อสอบที่เผยแพร่และตรงกับแพ็กเกจ
- การชำระ Pro Max ใช้ Supabase Edge Functions และ Stripe webhook; ห้ามเปิดสิทธิ์จากหน้าเว็บหรือข้อมูลที่ผู้ใช้ส่งเอง
- เมนู “นำเข้าไฟล์” สำหรับผู้ดูแลเท่านั้น รองรับ Word `.docx` และ PDF ที่มีข้อความจริง โดยอ่านไฟล์ในเบราว์เซอร์ ตรวจตัวอย่างก่อนเพิ่มแถวข้อสอบผ่าน RLS; PDF สแกนภาพไม่รองรับ OCR ดูรูปแบบที่ `question-import-template.txt`
- `claim_device_session`, `heartbeat_device_session`, `release_device_session` ใช้ device lease 90 วินาที จำกัดการใช้งานพร้อมกันหนึ่งอุปกรณ์ หากอุปกรณ์เดิมหลุดให้รอ lease หมดอายุก่อนเข้าสู่ระบบที่อีกเครื่อง

## เปิดระบบชำระ Pro Max จริง

สำหรับโปรเจ็กต์ที่มี billing-migration เดิม ให้รัน `lifetime-plan-migration.sql` หนึ่งครั้งก่อน Deploy เวอร์ชันราคาใหม่ โดยจะเก็บประวัติรายการเดิมไว้และตั้งสิทธิ์ Pro Max ใหม่เป็นตลอดชีพ

ราคาในโค้ดกำหนดไว้ที่ 199 บาทตลอดชีพ เป็นการชำระครั้งเดียว ไม่มีการต่ออายุ บัญชี Stripe ในไทยรองรับบัตรและ PromptPay สำหรับเงินบาท โดยการเปิดใช้และการรับเงินจริงต้องให้เจ้าของบัญชีทำ onboarding ของ Stripe เอง

1. สร้าง/ยืนยันบัญชี Stripe ประเทศไทยและผูกบัญชีรับเงินของเจ้าของระบบ เลือกเปิดรับบัตรและ PromptPay ตามที่บัญชีรองรับ
2. ในโปรเจ็กต์นี้ Deploy ฟังก์ชัน `create-checkout-session` และ `stripe-webhook` แล้ว หากติดตั้งในโปรเจ็กต์อื่น ให้ Deploy จากโฟลเดอร์ `functions/` โดยใช้ `config.toml` (Checkout ตรวจ JWT; webhook ปิด JWT เพราะตรวจ Stripe signature เอง)
3. ใน Supabase Dashboard → Edge Functions → Secrets ให้ตั้ง `STRIPE_SECRET_KEY` เป็น live secret key และ `STRIPE_EXPECT_LIVE` เป็น `true` ห้ามส่ง key นี้ให้ผู้ช่วยหรือใส่ใน GitHub
4. ใน Stripe Dashboard → Developers → Webhooks สร้าง endpoint `https://qubezdvomdkqzzgutgpf.supabase.co/functions/v1/stripe-webhook` และเลือก `checkout.session.completed` กับ `checkout.session.async_payment_succeeded`
5. เก็บ Signing secret ที่ขึ้นต้นด้วย `whsec_` ใน Supabase Edge Functions Secrets เป็น `STRIPE_WEBHOOK_SECRET` แล้วจึงทดลองชำระเงินจริงยอด 199 บาทและตรวจว่าโปรไฟล์ได้รับสิทธิ์ตลอดชีพ

ถ้ายังไม่ได้ตั้ง Secrets ฟังก์ชันจะปฏิเสธการชำระและยังไม่เปิด Pro Max การกลับจากหน้า Checkout อย่างเดียวไม่เปิดสิทธิ์ ต้องรอ webhook ยืนยันการชำระที่ตรงยอด 199 บาทเท่านั้น

