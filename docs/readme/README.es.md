# Configuración rápida de Ubuntu Server

[English](../../README.md) | [Русский](README.ru.md) | **Español** | [Deutsch](README.de.md) | [Français](README.fr.md) | [Português](README.pt.md) | [中文](README.zh-CN.md) | [日本語](README.ja.md) | [العربية](README.ar.md) | [हिन्दी](README.hi.md)

Conjunto modular de scripts Bash para la configuración inicial, seguridad, SSH, VPN, 3x-ui, WARP y copias de seguridad de Ubuntu Server.

> Para supervisar y administrar varios servidores desde una aplicación, consulte [Server Monitor Manager](https://github.com/ochenstarik-ui/server-monitor-manager). El proyecto se encuentra en una fase temprana de desarrollo.

## Instalación rápida

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -4 -fLO --retry 5 --retry-delay 10 --connect-timeout 30 \
  https://raw.githubusercontent.com/ochenstarik-ui/lightweight-server/main/ochenstarik-server-install.sh
chmod 700 ochenstarik-server-install.sh
sudo ./ochenstarik-server-install.sh
```

La primera pregunta selecciona el idioma del instalador; English es el valor predeterminado. Después puede instalar, omitir o detener cada una de las siete etapas.

## Etapas

1. Zona horaria, idioma del terminal, programas recomendados y swap.
2. Paquetes básicos, puerto SSH, IPv4/IPv6 y UFW.
3. Usuario administrador, clave SSH, permisos, sudo y fail2ban.
4. Notificaciones de Telegram para accesos SSH.
5. VPN del sistema mediante Xray.
6. Panel 3x-ui y proxy local Cloudflare WARP.
7. Instantánea inicial y copias diarias, semanales o mensuales.

No cierre la sesión SSH actual durante el cambio de puerto. Pruebe primero el nuevo acceso en otro terminal. Consulte la [documentación principal en inglés](../../README.md) para la instalación por archivo, actualización y restablecimiento.
