/**
 * MaaS · ส่งอีเมลยืนยันการจอง (Google Apps Script Web App)
 *
 * Edge Function "agent" ส่ง POST มาที่ Web App นี้ พร้อม { token, to, subject, html }
 * สคริปต์ตรวจ token แล้วส่งอีเมลจากบัญชี Gmail ของเจ้าของสคริปต์
 *
 * ตั้งค่า (ทำครั้งเดียว)
 *   1. Project Settings → Script Properties → เพิ่ม MAAS_TOKEN = รหัสลับ (ตั้งเอง เช่น maas-xxxx)
 *   2. Deploy → New deployment → Web app
 *        Execute as: Me   ·   Who has access: Anyone
 *   3. คัดลอก URL ที่ลงท้าย /exec ไปใส่ใน Supabase Secrets ชื่อ APPS_SCRIPT_URL
 *      และใส่ token เดียวกันใน APPS_SCRIPT_TOKEN
 */
function doPost(e) {
  try {
    const body = JSON.parse(e.postData.contents);
    const token = PropertiesService.getScriptProperties().getProperty('MAAS_TOKEN');

    if (!token || body.token !== token) return json({ ok: false, error: 'invalid token' });
    if (!body.to || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(body.to)) return json({ ok: false, error: 'invalid email' });

    MailApp.sendEmail({
      to: body.to,
      subject: String(body.subject || 'MaaS · ยืนยันการจอง').slice(0, 200),
      htmlBody: String(body.html || ''),
      name: 'MaaS Agent',
    });
    return json({ ok: true, remaining: MailApp.getRemainingDailyQuota() });
  } catch (err) {
    return json({ ok: false, error: String(err) });
  }
}

// ทดสอบในหน้า Apps Script: เลือกฟังก์ชัน testSend แล้วกด Run (ครั้งแรกจะขออนุญาตส่งอีเมล)
function testSend() {
  MailApp.sendEmail({
    to: Session.getActiveUser().getEmail(),
    subject: 'MaaS · ทดสอบส่งอีเมล',
    htmlBody: '<p>ถ้าได้รับอีเมลนี้ แปลว่า Apps Script ส่งอีเมลได้แล้ว ✅</p>',
  });
}

function json(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}
