cat << 'MASTEREOF' > /home/pi/setup_pico8_master.sh
#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "[!] Ejecuta el script con sudo: sudo bash setup_pico8_master.sh"
  exit 1
fi

echo "================================================="
echo "[+] INICIANDO INSTALACIÓN MAESTRA PICO-8 HANDHELD"
echo "================================================="

# 1. ACTUALIZACIÓN E INSTALACIÓN DE DEPENDENCIAS
echo "[+] 1/8. Instalando librerías y paquetes requeridos..."
apt-get update -y
apt-get install -y python3-lgpio
apt-get install -y python3-pip python3-pil python3-gpiozero python3-uinput \
                   python3-lgpio lgpio network-manager fonts-dejavu-core gcc make xinit xserver-xorg-video-fbdev

# 2. CONFIGURACIÓN DE ZONA HORARIA
echo "[+] 2/8. Configurando hora de Guatemala y sincronización NTP..."
timedatectl set-timezone America/Guatemala
timedatectl set-ntp true

# 3. OPTIMIZACIÓN DE ENERGÍA Y DESACTIVACIÓN DE BLUETOOTH
echo "[+] 3/8. Aplicando optimizaciones de energía y Bluetooth..."
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "$CONFIG_FILE" ] && CONFIG_FILE="/boot/config.txt"
grep -q "dtoverlay=disable-bt" "$CONFIG_FILE" || echo "dtoverlay=disable-bt" >> "$CONFIG_FILE"

systemctl disable bluetooth.service 2>/dev/null || true
systemctl disable hciuart.service 2>/dev/null || true
systemctl disable ModemManager.service 2>/dev/null || true

# 4. CONFIGURACIÓN DE PANTALLA XORG (32BPP NATIVO)
echo "[+] 4/8. Configurando servidor gráfico Xorg..."
mkdir -p /etc/X11/xorg.conf.d
cat << 'EOF' > /etc/X11/xorg.conf.d/99-fbdev.conf
Section "Device"
    Identifier "FbdevDevice"
    Driver "fbdev"
    Option "fbdev" "/dev/fb0"
EndSection

Section "Screen"
    Identifier "FbdevScreen"
    Device "FbdevDevice"
EndSection
EOF

# 5. COMPILACIÓN DEL DUPLICADOR LCD EN C
echo "[+] 5/8. Compilando driver LCD_Streamer en C..."
cat << 'EOF' > /home/pi/lcd_stream.c
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdint.h>
#include <string.h>
#include <lgpio.h>

#define FB_PATH "/dev/fb0"
#define WIDTH 128
#define HEIGHT 128
#define CHUNK_SIZE 4096

#define LCD_RST  27
#define LCD_DC   25
#define LCD_BL   24

int gpio_h = -1;
int spi_h = -1;

int get_bpp() {
    FILE *f = fopen("/sys/class/graphics/fb0/bits_per_pixel", "r");
    int bpp = 32;
    if (f) {
        if (fscanf(f, "%d", &bpp) != 1) bpp = 32;
        fclose(f);
    }
    return bpp;
}

void write_cmd(uint8_t cmd) {
    lgGpioWrite(gpio_h, LCD_DC, 0);
    lgSpiWrite(spi_h, (char*)&cmd, 1);
}

void write_data(uint8_t data) {
    lgGpioWrite(gpio_h, LCD_DC, 1);
    lgSpiWrite(spi_h, (char*)&data, 1);
}

void lcd_init() {
    lgGpioWrite(gpio_h, LCD_RST, 1);
    lguSleep(0.05);
    lgGpioWrite(gpio_h, LCD_RST, 0);
    lguSleep(0.05);
    lgGpioWrite(gpio_h, LCD_RST, 1);
    lguSleep(0.05);

    write_cmd(0xB1); write_data(0x01); write_data(0x2C); write_data(0x2D);
    write_cmd(0xB2); write_data(0x01); write_data(0x2C); write_data(0x2D);
    write_cmd(0xB3); write_data(0x01); write_data(0x2C); write_data(0x2D);
                     write_data(0x01); write_data(0x2C); write_data(0x2D);
    write_cmd(0xB4); write_data(0x07);

    write_cmd(0xC0); write_data(0xA2); write_data(0x02); write_data(0x84);
    write_cmd(0xC1); write_data(0xC5);
    write_cmd(0xC2); write_data(0x0A); write_data(0x00);
    write_cmd(0xC3); write_data(0x8A); write_data(0x2A);
    write_cmd(0xC4); write_data(0x8A); write_data(0xEE);
    write_cmd(0xC5); write_data(0x0E);

    write_cmd(0xE0);
    write_data(0x0F); write_data(0x1A); write_data(0x0F); write_data(0x18);
    write_data(0x2F); write_data(0x28); write_data(0x20); write_data(0x22);
    write_data(0x1F); write_data(0x1B); write_data(0x23); write_data(0x37);
    write_data(0x00); write_data(0x07); write_data(0x02); write_data(0x10);

    write_cmd(0xE1);
    write_data(0x0F); write_data(0x1B); write_data(0x0F); write_data(0x17);
    write_data(0x33); write_data(0x2C); write_data(0x29); write_data(0x2E);
    write_data(0x30); write_data(0x30); write_data(0x39); write_data(0x3F);
    write_data(0x00); write_data(0x07); write_data(0x03); write_data(0x10);

    write_cmd(0xF0); write_data(0x01);
    write_cmd(0xF6); write_data(0x00);
    write_cmd(0x3A); write_data(0x05);

    write_cmd(0x36); write_data(0x68);

    lguSleep(0.1);
    write_cmd(0x11);
    lguSleep(0.12);
    write_cmd(0x29);
    lgGpioWrite(gpio_h, LCD_BL, 1);
}

void set_windows(uint16_t xstart, uint16_t ystart, uint16_t xend, uint16_t yend) {
    write_cmd(0x2A);
    write_data(0x00); write_data((xstart & 0xFF) + 1);
    write_data(0x00); write_data(((xend - 1) & 0xFF) + 1);

    write_cmd(0x2B);
    write_data(0x00); write_data((ystart & 0xFF) + 2);
    write_data(0x00); write_data(((yend - 1) & 0xFF) + 2);

    write_cmd(0x2C);
}

int main() {
    int bpp = get_bpp();
    int bytes_per_pixel = bpp / 8;
    int mmap_size = WIDTH * HEIGHT * bytes_per_pixel;

    FILE *cpuinfo = popen("cat /proc/cpuinfo | grep 'Raspberry Pi 5'", "r");
    char buf[128];
    if (cpuinfo && fgets(buf, sizeof(buf), cpuinfo)) {
        gpio_h = lgGpiochipOpen(4);
    } else {
        gpio_h = lgGpiochipOpen(0);
    }
    if (cpuinfo) pclose(cpuinfo);

    if (gpio_h < 0) return 1;

    lgGpioFree(gpio_h, LCD_RST);
    lgGpioFree(gpio_h, LCD_DC);
    lgGpioFree(gpio_h, LCD_BL);

    lgGpioClaimOutput(gpio_h, 0, LCD_RST, 1);
    lgGpioClaimOutput(gpio_h, 0, LCD_DC, 0);
    lgGpioClaimOutput(gpio_h, 0, LCD_BL, 1);

    spi_h = lgSpiOpen(0, 0, 12000000, 0);
    if (spi_h < 0) return 1;

    lcd_init();

    int fb_fd = open(FB_PATH, O_RDONLY);
    if (fb_fd < 0) return 1;

    void *fb_ptr = mmap(NULL, mmap_size, PROT_READ, MAP_SHARED, fb_fd, 0);
    if (fb_ptr == MAP_FAILED) return 1;

    uint8_t tx_buf[WIDTH * HEIGHT * 2];

    while (1) {
        set_windows(0, 0, WIDTH, HEIGHT);
        lgGpioWrite(gpio_h, LCD_DC, 1);

        if (bpp == 32) {
            uint32_t *fb32 = (uint32_t *)fb_ptr;
            for (int i = 0; i < WIDTH * HEIGHT; i++) {
                uint32_t p = fb32[i];
                uint8_t r = (p >> 16) & 0xFF;
                uint8_t g = (p >> 8) & 0xFF;
                uint8_t b = p & 0xFF;
                uint16_t rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3);
                tx_buf[i * 2]     = (rgb565 >> 8) & 0xFF;
                tx_buf[i * 2 + 1] = rgb565 & 0xFF;
            }
        } else {
            uint16_t *fb16 = (uint16_t *)fb_ptr;
            for (int i = 0; i < WIDTH * HEIGHT; i++) {
                uint16_t pixel = fb16[i];
                tx_buf[i * 2]     = (pixel >> 8) & 0xFF;
                tx_buf[i * 2 + 1] = pixel & 0xFF;
            }
        }

        for (int offset = 0; offset < WIDTH * HEIGHT * 2; offset += CHUNK_SIZE) {
            lgSpiWrite(spi_h, (char*)&tx_buf[offset], CHUNK_SIZE);
        }

        usleep(16000);
    }

    munmap(fb_ptr, mmap_size);
    close(fb_fd);
    lgSpiClose(spi_h);
    lgGpiochipClose(gpio_h);
    return 0;
}
EOF

gcc -O3 /home/pi/lcd_stream.c -o /home/pi/lcd_stream_c -llgpio
chmod +x /home/pi/lcd_stream_c

# 6. CONTROLADOR DE BOTONES GPIO PARA JUEGO (0% CPU IDLE)
echo "[+] 6/8. Creando controlador de botones por interrupciones..."
cat << 'EOF' > /home/pi/pico8_gpio_controller.py
#!/usr/bin/env python3
import os
import time
import signal
import uinput
from gpiozero import Button

events = (
    uinput.KEY_UP,
    uinput.KEY_DOWN,
    uinput.KEY_LEFT,
    uinput.KEY_RIGHT,
    uinput.KEY_Z,
    uinput.KEY_X,
    uinput.KEY_ESC,
)

device = uinput.Device(events)

def safe_shutdown():
    os.system("sudo poweroff")

btn_up    = Button(6,  pull_up=True)
btn_down  = Button(19, pull_up=True)
btn_left  = Button(5,  pull_up=True)
btn_right = Button(26, pull_up=True)
btn_k1    = Button(21, pull_up=True)
btn_k2    = Button(20, pull_up=True)
btn_k3    = Button(16, pull_up=True, hold_time=5.0)

btn_up.when_pressed    = lambda: device.emit(uinput.KEY_UP, 1)
btn_up.when_released   = lambda: device.emit(uinput.KEY_UP, 0)

btn_down.when_pressed  = lambda: device.emit(uinput.KEY_DOWN, 1)
btn_down.when_released = lambda: device.emit(uinput.KEY_DOWN, 0)

btn_left.when_pressed  = lambda: device.emit(uinput.KEY_LEFT, 1)
btn_left.when_released = lambda: device.emit(uinput.KEY_LEFT, 0)

btn_right.when_pressed = lambda: device.emit(uinput.KEY_RIGHT, 1)
btn_right.when_released= lambda: device.emit(uinput.KEY_RIGHT, 0)

btn_k1.when_pressed    = lambda: device.emit(uinput.KEY_Z, 1)
btn_k1.when_released   = lambda: device.emit(uinput.KEY_Z, 0)

btn_k2.when_pressed    = lambda: device.emit(uinput.KEY_X, 1)
btn_k2.when_released   = lambda: device.emit(uinput.KEY_X, 0)

btn_k3.when_pressed    = lambda: device.emit(uinput.KEY_ESC, 1)
btn_k3.when_released   = lambda: device.emit(uinput.KEY_ESC, 0)
btn_k3.when_held       = safe_shutdown

signal.pause()
EOF

chmod +x /home/pi/pico8_gpio_controller.py

# 7. LANZADOR INTERACTIVO CON RELOJ, WIFI, BRILLO Y CORTINILLA DE CARGA
echo "[+] 7/8. Creando lanzador interactivo de pantalla de inicio..."
cat << 'EOF' > /home/pi/pico8_launcher.py
#!/usr/bin/env python3
import os
import time
import socket
import subprocess
from PIL import Image, ImageDraw, ImageFont
from gpiozero import Button
import LCD_1in44

lg_h = -1
pwm_rpi = None
brillo_actual = 100

def init_backlight():
    global lg_h, pwm_rpi
    try:
        import lgpio
        chip = 4 if (os.path.exists("/proc/device-tree/model") and "Raspberry Pi 5" in open("/proc/device-tree/model").read()) else 0
        lg_h = lgpio.gpiochip_open(chip)
        lgpio.tx_pwm(lg_h, 24, 1000, 100)
        return
    except Exception:
        pass

    try:
        import RPi.GPIO as GPIO
        GPIO.setmode(GPIO.BCM)
        GPIO.setwarnings(False)
        GPIO.setup(24, GPIO.OUT)
        pwm_rpi = GPIO.PWM(24, 1000)
        pwm_rpi.start(100)
    except Exception:
        pass

def aplicar_brillo(porcentaje):
    global lg_h, pwm_rpi, brillo_actual
    brillo_actual = porcentaje
    if lg_h >= 0:
        try:
            import lgpio
            lgpio.tx_pwm(lg_h, 24, 1000, porcentaje)
        except Exception:
            pass
    elif pwm_rpi is not None:
        try:
            pwm_rpi.ChangeDutyCycle(porcentaje)
        except Exception:
            pass

def obtener_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return f"IP: {ip}", True
    except Exception:
        return "IP: Sin Conexión", False

font_paths = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf"
]

def load_font(size):
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                return ImageFont.truetype(fp, size)
            except Exception:
                pass
    try:
        return ImageFont.load_default(size=size)
    except Exception:
        return ImageFont.load_default()

font_time    = load_font(32)
font_loading = load_font(13)
font_title   = load_font(10)
font_ip      = load_font(10)
font_btn     = load_font(8)
font_kb      = load_font(9)

def get_text_width(draw, text, font):
    if hasattr(font, 'getbbox'):
        bbox = font.getbbox(text)
        return bbox[2] - bbox[0]
    elif hasattr(draw, 'textbbox'):
        bbox = draw.textbbox((0, 0), text, font=font)
        return bbox[2] - bbox[0]
    return len(text) * 6

def draw_centered_text(draw, y, text, font, fill, width=128):
    w = get_text_width(draw, text, font)
    x = (width - w) // 2
    draw.text((x, y), text, font=font, fill=fill)
    return x, w

def mostrar_cargando_inicio(disp):
    image = Image.new('RGB', (128, 128), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    colors_pico8 = [(255, 163, 0), (255, 236, 39), (0, 228, 54), (41, 173, 255)]
    
    for i, col in enumerate(colors_pico8):
        x = 52 + (i * 6)
        draw.rectangle([(x, 15), (x + 4, 19)], fill=col)

    draw_centered_text(draw, 32, "SISTEMA PICO-8", font_ip, fill=(194, 195, 199))
    draw_centered_text(draw, 46, "CARGANDO...", font_loading, fill=(0, 228, 242))

    draw.rectangle([(14, 75), (114, 87)], outline=(0, 228, 242), fill=(15, 23, 42))
    draw.rectangle([(16, 77), (112, 85)], fill=(0, 228, 54))

    disp.LCD_ShowImage(image, 0, 0)
    time.sleep(0.8)

def apagar_pantalla_inicio(disp):
    image = Image.new('RGB', (128, 128), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle([(8, 48), (119, 80)], radius=4, fill=(255, 0, 77))
    draw_centered_text(draw, 58, "APAGANDO...", font_loading, fill=(255, 255, 255))
    disp.LCD_ShowImage(image, 0, 0)
    time.sleep(1.5)
    disp.module_exit()
    os.system("sudo poweroff")

def brightness_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3):
    global brillo_actual
    while True:
        image = Image.new('RGB', (128, 128), (0, 0, 0))
        draw = ImageDraw.Draw(image)

        draw.rectangle([(0, 0), (127, 13)], fill=(255, 163, 0))
        draw_centered_text(draw, 1, "AJUSTE DE BRILLO", font_title, (0, 0, 0))

        draw_centered_text(draw, 24, f"{brillo_actual}%", font_time, fill=(255, 236, 39))

        draw.rectangle([(14, 66), (114, 80)], outline=(0, 228, 242), fill=(15, 23, 42), width=1)
        ancho_relleno = int((brillo_actual / 100.0) * 96)
        if ancho_relleno > 0:
            draw.rectangle([(16, 68), (16 + ancho_relleno, 78)], fill=(0, 228, 54))

        draw_centered_text(draw, 92, "◄/► : AJUSTAR", font_btn, fill=(194, 195, 199))
        draw_centered_text(draw, 106, "CENTRO / K3 : SALIR", font_btn, fill=(255, 0, 77))

        disp.LCD_ShowImage(image, 0, 0)
        time.sleep(0.08)

        if btn_left.is_pressed or btn_down.is_pressed:
            brillo_actual = max(10, brillo_actual - 10)
            aplicar_brillo(brillo_actual)
            time.sleep(0.12)

        if btn_right.is_pressed or btn_up.is_pressed:
            brillo_actual = min(100, brillo_actual + 10)
            aplicar_brillo(brillo_actual)
            time.sleep(0.12)

        if btn_center.is_pressed or btn_k3.is_pressed or btn_k2.is_pressed:
            time.sleep(0.2)
            return

def scan_wifi_networks():
    try:
        subprocess.run(["nmcli", "dev", "wifi", "rescan"], capture_output=True, timeout=4)
    except Exception:
        pass
    try:
        res = subprocess.run(["nmcli", "-t", "-f", "SSID,SIGNAL", "dev", "wifi", "list"], capture_output=True, text=True, timeout=5)
        lines = res.stdout.strip().split('\n')
        networks = []
        seen = set()
        for line in lines:
            if not line or ':' not in line:
                continue
            parts = line.split(':')
            if len(parts) >= 2:
                ssid = parts[0].strip()
                signal = parts[1].strip()
                if ssid and ssid != "--" and ssid not in seen:
                    seen.add(ssid)
                    networks.append({'ssid': ssid, 'signal': signal})
        return networks
    except Exception:
        return []

def connect_wifi(ssid, password):
    try:
        cmd = ["nmcli", "dev", "wifi", "connect", ssid]
        if password:
            cmd.extend(["password", password])
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return res.returncode == 0
    except Exception:
        return False

grid_layouts = [
    [['a','b','c','d','e','f','g'],['h','i','j','k','l','m','n'],['o','p','q','r','s','t','u'],['v','w','x','y','z','0','1'],['2','3','4','5','6','7','8'],['9','.','_','-','^','<','=']],
    [['A','B','C','D','E','F','G'],['H','I','J','K','L','M','N'],['O','P','Q','R','S','T','U'],['V','W','X','Y','Z','0','1'],['2','3','4','5','6','7','8'],['9','.','_','-','^','<','=']],
    [['!','@','#','$','%','^','&'],['*','(',')','+','=','{','}'],['[',']',':',';','"',"'",'<'],['>',',','?','/','\\','|','~'],['`','0','1','2','3','4','5'],['6','7','8','9','^','<','=']]
]

def render_keyboard(ssid, password, mode, sel_r, sel_c):
    img = Image.new('RGB', (128, 128), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rectangle([(0, 0), (127, 13)], fill=(255, 0, 77))
    draw_centered_text(draw, 1, f"WIFI: {ssid[:12]}", font_title, (255, 255, 255))
    draw.rectangle([(4, 16), (123, 31)], outline=(0, 228, 242), fill=(15, 23, 42))
    pass_disp = password[-13:] if len(password) > 13 else password
    draw.text((8, 18), pass_disp + "_", font=font_title, fill=(255, 236, 39))
    
    start_x, start_y = 6, 34
    cell_w, cell_h = 16, 14
    grid = grid_layouts[mode]
    for r in range(6):
        for c in range(7):
            cx, cy = start_x + c * cell_w, start_y + r * cell_h
            char = grid[r][c]
            if r == sel_r and c == sel_c:
                draw.rounded_rectangle([(cx, cy), (cx + cell_w - 2, cy + cell_h - 2)], radius=2, fill=(0, 228, 54))
                draw.text((cx + 4, cy + 1), char, font=font_kb, fill=(0, 0, 0))
            else:
                draw.rounded_rectangle([(cx, cy), (cx + cell_w - 2, cy + cell_h - 2)], radius=2, fill=(30, 41, 59))
                draw.text((cx + 4, cy + 1), char, font=font_kb, fill=(255, 255, 255))
    return img

def keyboard_input_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3, ssid):
    password = ""
    mode = 0
    sel_r, sel_c = 0, 0
    while True:
        img = render_keyboard(ssid, password, mode, sel_r, sel_c)
        disp.LCD_ShowImage(img, 0, 0)
        time.sleep(0.08)
        if btn_up.is_pressed:    sel_r = (sel_r - 1) % 6; time.sleep(0.12)
        if btn_down.is_pressed:  sel_r = (sel_r + 1) % 6; time.sleep(0.12)
        if btn_left.is_pressed:  sel_c = (sel_c - 1) % 7; time.sleep(0.12)
        if btn_right.is_pressed: sel_c = (sel_c + 1) % 7; time.sleep(0.12)
        if btn_k2.is_pressed: password = password[:-1]; time.sleep(0.15)
        if btn_k3.is_pressed or btn_center.is_pressed: return None
        if btn_k1.is_pressed:
            char = grid_layouts[mode][sel_r][sel_c]
            if char == '^': mode = (mode + 1) % 3
            elif char == '<': password = password[:-1]
            elif char == '=': return password
            else: password += char
            time.sleep(0.18)

def wifi_scan_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3):
    img = Image.new('RGB', (128, 128), (0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_centered_text(draw, 45, "BUSCANDO", font_ip, fill=(194, 195, 199))
    draw_centered_text(draw, 58, "REDES WIFI...", font_loading, fill=(0, 228, 242))
    disp.LCD_ShowImage(img, 0, 0)
    
    networks = scan_wifi_networks()
    if not networks:
        img = Image.new('RGB', (128, 128), (0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw_centered_text(draw, 50, "NO SE HALLARON", font_ip, fill=(255, 0, 77))
        draw_centered_text(draw, 65, "REDES WIFI", font_ip, fill=(255, 0, 77))
        disp.LCD_ShowImage(img, 0, 0)
        time.sleep(1.5)
        return False

    options = [f"{n['ssid'][:11]} ({n['signal']}%)" for n in networks] + ["[ CANCELAR ]"]
    selected = 0
    while True:
        img = Image.new('RGB', (128, 128), (0, 0, 0))
        draw = ImageDraw.Draw(img)
        draw.rectangle([(0, 0), (127, 13)], fill=(0, 228, 242))
        draw_centered_text(draw, 1, "REDES ENCONTRADAS", font_title, (0, 0, 0))
        
        start = max(0, min(selected - 2, len(options) - 5))
        for i in range(start, min(start + 5, len(options))):
            y = 18 + (i - start) * 21
            if i == selected:
                draw.rounded_rectangle([(4, y), (123, y + 18)], radius=3, fill=(255, 0, 77))
                draw.text((8, y + 2), options[i], font=font_ip, fill=(255, 255, 255))
            else:
                draw.rounded_rectangle([(4, y), (123, y + 18)], radius=3, fill=(15, 23, 42))
                draw.text((8, y + 2), options[i], font=font_ip, fill=(148, 163, 184))

        disp.LCD_ShowImage(img, 0, 0)
        time.sleep(0.08)
        if btn_up.is_pressed:   selected = (selected - 1) % len(options); time.sleep(0.12)
        if btn_down.is_pressed: selected = (selected + 1) % len(options); time.sleep(0.12)
        if btn_k2.is_pressed or btn_k3.is_pressed or btn_center.is_pressed: return False

        if btn_k1.is_pressed:
            time.sleep(0.2)
            if selected == len(options) - 1: return False
            chosen_ssid = networks[selected]['ssid']
            password = keyboard_input_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3, chosen_ssid)
            if password is not None:
                img = Image.new('RGB', (128, 128), (0, 0, 0))
                draw = ImageDraw.Draw(img)
                draw_centered_text(draw, 45, "CONECTANDO A", font_ip, fill=(194, 195, 199))
                draw_centered_text(draw, 58, f"{chosen_ssid[:12]}...", font_loading, fill=(255, 236, 39))
                disp.LCD_ShowImage(img, 0, 0)
                
                success = connect_wifi(chosen_ssid, password)
                img = Image.new('RGB', (128, 128), (0, 0, 0))
                draw = ImageDraw.Draw(img)
                if success:
                    draw_centered_text(draw, 50, "¡CONECTADO!", font_loading, fill=(0, 228, 54))
                    disp.LCD_ShowImage(img, 0, 0)
                    time.sleep(1.5)
                    return True
                else:
                    draw_centered_text(draw, 50, "ERROR DE CLAVE", font_loading, fill=(255, 0, 77))
                    disp.LCD_ShowImage(img, 0, 0)
                    time.sleep(1.5)

def main():
    disp = LCD_1in44.LCD()
    disp.LCD_Init(LCD_1in44.SCAN_DIR_DFT)
    disp.LCD_Clear()
    time.sleep(0.1)

    init_backlight()
    mostrar_cargando_inicio(disp)

    btn_up     = Button(6,  pull_up=True)
    btn_down   = Button(19, pull_up=True)
    btn_left   = Button(5,  pull_up=True)
    btn_right  = Button(26, pull_up=True)
    btn_center = Button(13, pull_up=True, hold_time=5.0)
    btn_k1     = Button(21, pull_up=True)
    btn_k2     = Button(20, pull_up=True)
    btn_k3     = Button(16, pull_up=True)

    time.sleep(0.2)

    mostrar_dos_puntos = True
    colors_pico8 = [(255, 163, 0), (255, 236, 39), (0, 228, 54), (41, 173, 255)]

    while True:
        ip_str, wifi_ok = obtener_ip()

        if btn_center.is_held:
            apagar_pantalla_inicio(disp)

        if btn_k1.is_pressed:
            aplicar_brillo(100)
            break

        if btn_k2.is_pressed:
            wifi_scan_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3)
            time.sleep(0.3)
            continue

        if btn_k3.is_pressed:
            brightness_menu(disp, btn_up, btn_down, btn_left, btn_right, btn_center, btn_k1, btn_k2, btn_k3)
            time.sleep(0.3)
            continue

        image = Image.new('RGB', (128, 128), (0, 0, 0))
        draw = ImageDraw.Draw(image)

        for i, col in enumerate(colors_pico8):
            x = 52 + (i * 6)
            draw.rectangle([(x, 4), (x + 4, 8)], fill=col)

        wifi_color = (0, 228, 54) if wifi_ok else (255, 0, 77)
        draw.ellipse([(116, 4), (121, 9)], fill=wifi_color)

        formato = "%H:%M" if mostrar_dos_puntos else "%H %M"
        hora = time.strftime(formato)
        draw_centered_text(draw, 12, hora, font_time, fill=(255, 236, 39))
        mostrar_dos_puntos = not mostrar_dos_puntos

        draw.line([(16, 52), (112, 52)], fill=(255, 0, 77), width=1)

        draw_centered_text(draw, 56, ip_str, font_ip, fill=(0, 228, 242))

        draw.rounded_rectangle([(10, 74), (117, 88)], radius=3, fill=(0, 228, 54))
        draw_centered_text(draw, 76, "KEY1: PICO-8", font_btn, fill=(0, 0, 0))

        draw.rounded_rectangle([(10, 91), (117, 105)], radius=3, fill=(0, 228, 242))
        draw_centered_text(draw, 93, "KEY2: WIFI", font_btn, fill=(0, 0, 0))

        draw.rounded_rectangle([(10, 108), (117, 122)], radius=3, fill=(255, 163, 0))
        draw_centered_text(draw, 110, "KEY3: BRILLO", font_btn, fill=(0, 0, 0))

        disp.LCD_ShowImage(image, 0, 0)
        time.sleep(0.4)

    image = Image.new('RGB', (128, 128), (0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw_centered_text(draw, 42, "INICIANDO", font_ip, fill=(194, 195, 199))
    draw_centered_text(draw, 58, "PICO-8...", font_loading, fill=(0, 228, 54))
    disp.LCD_ShowImage(image, 0, 0)
    time.sleep(0.4)
    disp.module_exit()

if __name__ == '__main__':
    main()
EOF

chmod +x /home/pi/pico8_launcher.py

# 8. SCRIPT DE ARRANQUE GENERAL Y SERVICIO SYSTEMD
echo "[+] 8/8. Configurando script de inicio master y servicio de arranque..."
cat << 'EOF' > /home/pi/start_pico8.sh
#!/bin/bash

export XDG_RUNTIME_DIR=/tmp
export SDL_AUDIODRIVER=dummy

pkill -f pico8_launcher.py || true
pkill -f pico8_gpio_controller.py || true
pkill -f lcd_stream.py || true
pkill -f lcd_stream_c || true
pkill -f xinit || true
pkill -x pico8_dyn || true
pkill -x pico8 || true
sleep 1

# Apagar salida HDMI para ahorro de batería
vcgencmd display_power 0 2>/dev/null || true

# 1. Ejecutar Lanzador interactivo
python3 /home/pi/pico8_launcher.py

# 2. Arrancar servicios de juego tras presionar KEY1
nice -n -10 python3 /home/pi/pico8_gpio_controller.py &
nice -n -10 /home/pi/lcd_stream_c &
sleep 1

cd /home/pi
nice -n -10 xinit ./pico8_dyn -splore -windowed 0 -- :0 -nocursor -nolisten tcp
EOF

chmod +x /home/pi/start_pico8.sh

cat << 'EOF' > /etc/systemd/system/pico8.service
[Unit]
Description=PICO-8 Handheld Console Master Service
After=multi-user.target

[Service]
Type=simple
User=root
ExecStart=/home/pi/start_pico8.sh
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable pico8.service

echo "================================================="
echo "[✔] INSTALACIÓN MAESTRA COMPLETADA CON ÉXITO"
echo "Recuerda copiar el ejecutable 'pico8_dyn' en /home/pi/"
echo "Reinicia la consola con: sudo reboot"
echo "================================================="
MASTEREOF

sudo bash /home/pi/setup_pico8_master.sh
