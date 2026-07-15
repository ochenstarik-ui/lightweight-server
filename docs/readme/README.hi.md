# Ubuntu Server का त्वरित सेटअप

[English](../../README.md) | [Русский](README.ru.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Português](README.pt.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [العربية](README.ar.md) | **हिन्दी**

Ubuntu Server की प्रारंभिक स्थापना, सुरक्षा, SSH, VPN, 3x-ui, WARP और बैकअप के लिए मॉड्यूलर Bash स्क्रिप्ट।

> एक ऐप से कई सर्वरों की निगरानी और संयुक्त प्रबंधन के लिए [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager) का उपयोग करें। यह परियोजना अभी शुरुआती विकास चरण में है।

## त्वरित स्थापना

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

पहला प्रश्न इंस्टॉलर की भाषा चुनता है; डिफ़ॉल्ट English है। इसके बाद सातों चरणों को चलाया, छोड़ा या इंस्टॉलर बंद किया जा सकता है।

## चरण

1. समय क्षेत्र, टर्मिनल भाषा, अनुशंसित प्रोग्राम और swap।
2. मूल पैकेज, SSH पोर्ट, IPv4/IPv6 और UFW।
3. प्रशासक, SSH कुंजी, अनुमतियाँ, sudo और fail2ban।
4. SSH लॉगिन के लिए Telegram सूचनाएँ।
5. Xray के माध्यम से सिस्टम VPN।
6. 3x-ui पैनल और स्थानीय Cloudflare WARP प्रॉक्सी।
7. प्रारंभिक स्नैपशॉट और दैनिक, साप्ताहिक या मासिक बैकअप।

SSH पोर्ट बदलते समय मौजूदा सत्र बंद न करें। पहले दूसरे टर्मिनल में नया लॉगिन जाँचें। अधिक जानकारी के लिए [मुख्य अंग्रेज़ी दस्तावेज़](../../README.md) देखें।
