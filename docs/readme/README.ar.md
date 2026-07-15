# الإعداد السريع لخادم Ubuntu

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Português](README.pt.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | **العربية** | [हिन्दी](README.hi.md)

مجموعة نصوص Bash مستقلة لإعداد Ubuntu Server وتأمينه وإدارة SSH وVPN و3x-ui وWARP والنسخ الاحتياطية.

> لمراقبة عدة خوادم وإدارتها من تطبيق واحد، استخدم [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager). المشروع ما زال في مرحلة تطوير مبكرة.

## التثبيت السريع

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

السؤال الأول يحدد لغة المثبت، واللغة الافتراضية هي English. بعد ذلك يمكن تشغيل كل مرحلة من المراحل الثماني أو تخطيها أو إنهاء المثبت.

## المراحل

1. المنطقة الزمنية ولغة الطرفية والبرامج وملف swap.
2. الحزم الأساسية ومنفذ SSH وIPv4/IPv6 وUFW.
3. المستخدم الإداري ومفتاح SSH والصلاحيات وsudo وfail2ban.
4. إشعارات Telegram عند تسجيل الدخول عبر SSH.
5. VPN للنظام باستخدام Xray.
6. لوحة 3x-ui ووكيل Cloudflare WARP المحلي.
7. النسخة الأولية والنسخ اليومية أو الأسبوعية أو الشهرية.
8. وكلاء ذكاء اصطناعي اختياريون: Hermes أو OpenClaw أو OpenHands أو OpenCode أو Aider.

لا تغلق جلسة SSH الحالية أثناء تغيير المنفذ. اختبر الاتصال الجديد أولاً في طرفية أخرى. راجع [الوثائق الإنجليزية الرئيسية](../../README.md) لمزيد من التفاصيل.
