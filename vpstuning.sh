#!/bin/bash

# Скрипт оптимизации сети VPS
# Универсальный для Debian 11+ / Ubuntu 20.04+
# Конфигурация: BBR + FQ + ICMP Stealth + автодетект MTU
# Совместимость: KVM, Xen, VMware и большинство современных виртуализаций

set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # Без цвета

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Пожалуйста, запустите от root (sudo)${NC}"
    exit 1
fi

# Функция: Определение сетевого интерфейса
detect_interface() {
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}Не удалось автоматически определить сетевой интерфейс!${NC}"
        echo "Доступные интерфейсы:"
        ip link show | grep -E "^[0-9]+" | awk -F': ' '{print "  - " $2}'
        echo ""
        read -p "Введите имя интерфейса вручную (например, ens3, eth0): " INTERFACE
        
        if [ -z "$INTERFACE" ]; then
            echo -e "${RED}Интерфейс не указан. Выход.${NC}"
            exit 1
        fi
    fi
    
    # Проверка существования интерфейса
    if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
        echo -e "${RED}Интерфейс $INTERFACE не существует!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}✓ Обнаружен интерфейс: $INTERFACE${NC}"
}

# Функция: Автоматическое определение MTU
auto_detect_mtu() {
    echo -e "${YELLOW}Тестирование оптимального MTU...${NC}"
    MTU_FOUND=false
    OPTIMAL_MTU=1500
    TEST_HOST="8.8.8.8"
    
    echo "Тестирование с помощью ICMP ping к $TEST_HOST..."
    for size in 1472 1450 1400 1350 1300 1250; do
        if timeout 3 ping -c 2 -W 2 -M do -s $size $TEST_HOST >/dev/null 2>&1; then
            OPTIMAL_MTU=$((size + 28))  # +8 ICMP +20 IP
            MTU_FOUND=true
            echo -e "${GREEN}✓ Тест MTU пройден с payload $size → MTU = $OPTIMAL_MTU${NC}"
            break
        fi
    done
    
    # Запасной вариант
    if [ "$MTU_FOUND" = false ]; then
        CURRENT_MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+' || echo "1500")
        echo -e "${YELLOW}⚠ Ping-тест не прошёл (ICMP может быть заблокирован)${NC}"
        echo -e "${YELLOW}  Используется текущий MTU интерфейса: $CURRENT_MTU${NC}"
        OPTIMAL_MTU=$CURRENT_MTU
    fi
    
    echo -e "${BLUE}ℹ Обнаруженный MTU: $OPTIMAL_MTU${NC}"
}

# Функция: Применение MTU к интерфейсу
apply_mtu() {
    local mtu_value=$1
    local interface=$2
    
    echo -e "${YELLOW}Применение MTU $mtu_value к интерфейсу $interface...${NC}"
    
    # Применить немедленно
    if ip link set dev $interface mtu $mtu_value 2>/dev/null; then
        echo -e "${GREEN}✓ MTU успешно установлен: $mtu_value${NC}"
    else
        echo -e "${YELLOW}⚠ Не удалось установить MTU (возможно, не поддерживается)${NC}"
        return 1
    fi
    
    # Сделать постоянным через несколько методов
    
    # Метод 1: systemd-networkd
    if [ -d /etc/systemd/network ]; then
        mkdir -p /etc/systemd/network
        cat > /etc/systemd/network/10-${interface}-mtu.network <<EOF
[Match]
Name=$interface

[Link]
MTUBytes=$mtu_value
EOF
        echo -e "${BLUE}  ℹ Создан: /etc/systemd/network/10-${interface}-mtu.network${NC}"
    fi
    
    # Метод 2: ifupdown (classic Debian)
    if [ -f /etc/network/interfaces ]; then
        if ! grep -q "post-up ip link set dev $interface mtu" /etc/network/interfaces 2>/dev/null; then
            echo "" >> /etc/network/interfaces
            echo "# MTU настройка для $interface (добавлено скриптом)" >> /etc/network/interfaces
            echo "post-up ip link set dev $interface mtu $mtu_value" >> /etc/network/interfaces
            echo -e "${BLUE}  ℹ Добавлено в /etc/network/interfaces${NC}"
        fi
    fi
    
    # Метод 3: crontab (универсальный)
    TEMP_CRON=$(mktemp)
    crontab -l > "$TEMP_CRON" 2>/dev/null || true
    sed -i "/ip link set dev $interface mtu/d" "$TEMP_CRON"
    sed -i "/# mtu-setting/d" "$TEMP_CRON"
    echo "@reboot /bin/sleep 10 && /usr/sbin/ip link set dev $interface mtu $mtu_value # mtu-setting" >> "$TEMP_CRON"
    crontab "$TEMP_CRON" 2>/dev/null
    rm -f "$TEMP_CRON"
    echo -e "${BLUE}  ℹ Добавлено в crontab для автоприменения${NC}"
    
    return 0
}

# Функция: Ручная установка MTU
# Функция: Ручная установка MTU
manual_set_mtu() {
    echo ""
    echo -e "${CYAN}=== Ручная установка MTU ===${NC}"
    echo ""
    
    # Показать текущий MTU
    CURRENT_MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+' || echo "неизвестно")
    echo -e "Текущий MTU интерфейса ${YELLOW}$INTERFACE${NC}: ${GREEN}$CURRENT_MTU${NC}"
    echo ""
    
    # Рекомендации
    echo -e "${BLUE}Рекомендации по MTU:${NC}"
    echo "  • Стандартный Ethernet: 1500"
    echo "  • PPPoE подключение: 1492"
    echo "  • VPN/туннель: 1400-1450"
    echo "  • Jumbo frames: 9000"
    echo ""
    
    # Запрос нового значения
    while true; do
        read -p "Введите желаемое значение MTU (576-9000) или 'auto' для автоопределения: " USER_MTU
        
        # Проверка на автоопределение
        if [ "$USER_MTU" = "auto" ] || [ "$USER_MTU" = "AUTO" ]; then
            echo ""
            auto_detect_mtu
            USER_MTU=$OPTIMAL_MTU
            break
        fi
        
        # Проверка на число
        if ! [[ "$USER_MTU" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Ошибка: Введите число или 'auto'${NC}"
            continue
        fi
        
        # Проверка диапазона
        if [ "$USER_MTU" -lt 576 ] || [ "$USER_MTU" -gt 9000 ]; then
            echo -e "${RED}Ошибка: MTU должен быть в диапазоне 576-9000${NC}"
            continue
        fi
        
        break
    done
    
    OPTIMAL_MTU=$USER_MTU
    
    # Применение MTU
    echo ""
    echo -e "${YELLOW}Применение MTU $OPTIMAL_MTU на интерфейсе $INTERFACE...${NC}"
    
    if ip link set dev $INTERFACE mtu $OPTIMAL_MTU 2>/dev/null; then
        echo -e "${GREEN}✓ MTU успешно установлен: $OPTIMAL_MTU${NC}"
    else
        echo -e "${RED}✗ Не удалось установить MTU${NC}"
        echo -e "${YELLOW}  Возможно, значение не поддерживается вашим оборудованием${NC}"
        return 1
    fi
    
    # Настройка постоянного MTU
    echo ""
    read -p "Сделать MTU постоянным после перезагрузки? (y/n): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Обновление настроек автозагрузки...${NC}"
        
        # Обновление crontab
        TEMP_CRON=$(mktemp)
        crontab -l > "$TEMP_CRON" 2>/dev/null || true
        
        # Проверка: есть ли основная запись vps-tuning?
        if grep -q "# vps-tuning" "$TEMP_CRON" 2>/dev/null; then
            echo -e "${BLUE}ℹ Обнаружена запись vps-tuning, обновляю MTU в ней...${NC}"
            
            # Обновить MTU в существующей записи vps-tuning
            sed -i "s|mtu [0-9]\+|mtu $OPTIMAL_MTU|g" "$TEMP_CRON"
            
            # Удалить старую запись mtu-setting если есть
            sed -i '/# mtu-setting/d' "$TEMP_CRON"
            
            echo -e "${GREEN}✓ MTU обновлён в основной записи vps-tuning${NC}"
        else
            echo -e "${BLUE}ℹ Основной записи vps-tuning нет, создаю отдельную запись MTU...${NC}"
            
            # Удалить старую mtu-setting запись
            sed -i '/# mtu-setting/d' "$TEMP_CRON"
            
            # Создать новую запись только для MTU
            echo "@reboot /bin/sleep 10 && /usr/sbin/ip link set dev $INTERFACE mtu $OPTIMAL_MTU # mtu-setting" >> "$TEMP_CRON"
            
            echo -e "${GREEN}✓ Создана запись для автоприменения MTU${NC}"
        fi
        
        # Применить новый crontab
        if crontab "$TEMP_CRON" 2>/dev/null; then
            echo -e "${GREEN}✓ Crontab обновлён${NC}"
        else
            echo -e "${YELLOW}⚠ Не удалось обновить crontab${NC}"
        fi
        rm -f "$TEMP_CRON"
        
        # Обновление других методов (необязательно, но для полноты)
        # Метод 1: systemd-networkd
        if [ -d /etc/systemd/network ]; then
            mkdir -p /etc/systemd/network
            cat > /etc/systemd/network/10-${INTERFACE}-mtu.network <<EOF
[Match]
Name=$INTERFACE

[Link]
MTUBytes=$OPTIMAL_MTU
EOF
            echo -e "${BLUE}  ℹ Обновлён: /etc/systemd/network/10-${INTERFACE}-mtu.network${NC}"
        fi
        
        # Метод 2: ifupdown (classic Debian)
        if [ -f /etc/network/interfaces ]; then
            # Удалить старую запись MTU
            sed -i "/# MTU настройка для $INTERFACE/d" /etc/network/interfaces
            sed -i "/post-up ip link set dev $INTERFACE mtu/d" /etc/network/interfaces
            
            # Добавить новую
            echo "" >> /etc/network/interfaces
            echo "# MTU настройка для $INTERFACE (обновлено скриптом)" >> /etc/network/interfaces
            echo "post-up ip link set dev $INTERFACE mtu $OPTIMAL_MTU" >> /etc/network/interfaces
            echo -e "${BLUE}  ℹ Обновлён /etc/network/interfaces${NC}"
        fi
    fi
    
    echo ""
    echo -e "${GREEN}✓✓✓ MTU успешно настроен! ✓✓✓${NC}"
    echo ""
}

# Функция: Полная автоматическая настройка
full_optimization() {
    echo ""
    echo -e "${CYAN}=== Автоматическая оптимизация VPS ===${NC}"
    echo "Версия: 2.2 (С применением MTU)"
    echo ""
    
    # Шаг 0: Определение типа виртуализации
    echo -e "${BLUE}[0/8] Определение типа виртуализации...${NC}"
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    
    echo -e "${GREEN}✓ Виртуализация: $VIRT_TYPE${NC}"
    
    # Предупреждение об ограничениях OpenVZ/LXC
    if [ "$VIRT_TYPE" = "openvz" ] || [ "$VIRT_TYPE" = "lxc" ]; then
        echo -e "${YELLOW}⚠ ВНИМАНИЕ: Обнаружен $VIRT_TYPE!${NC}"
        echo -e "${YELLOW}  BBR может работать некорректно (ограниченный доступ к ядру)${NC}"
        read -p "Продолжить? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Прервано пользователем."
            return 1
        fi
    fi
    echo ""
    
    # Шаг 1: Определение сетевого интерфейса
    echo -e "${YELLOW}[1/8] Определение сетевого интерфейса...${NC}"
    detect_interface
    echo ""
    
    # Шаг 2: Определение оптимального MTU
    echo -e "${YELLOW}[2/8] Определение оптимального MTU...${NC}"
    auto_detect_mtu
    echo ""
    
    # Шаг 2.5: ПРИМЕНЕНИЕ MTU (НОВОЕ!)
    echo -e "${YELLOW}[3/8] Применение оптимального MTU...${NC}"
    CURRENT_MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+' || echo "0")
    
    if [ "$CURRENT_MTU" != "$OPTIMAL_MTU" ]; then
        echo "Текущий MTU: $CURRENT_MTU → Оптимальный MTU: $OPTIMAL_MTU"
        apply_mtu $OPTIMAL_MTU $INTERFACE
    else
        echo -e "${GREEN}✓ MTU уже установлен корректно: $OPTIMAL_MTU${NC}"
    fi
    echo ""
    
    # Шаг 3: Проверка доступности BBR
    echo -e "${YELLOW}[4/8] Проверка доступности BBR...${NC}"
    BBR_AVAILABLE=false
    
    modprobe tcp_bbr 2>/dev/null || true
    
    if grep -q "tcp_bbr" /proc/modules 2>/dev/null; then
        BBR_AVAILABLE=true
        echo -e "${GREEN}✓ Модуль BBR загружен${NC}"
    elif grep -q "CONFIG_TCP_CONG_BBR=y" /boot/config-$(uname -r) 2>/dev/null; then
        BBR_AVAILABLE=true
        echo -e "${GREEN}✓ BBR встроен в ядро${NC}"
    else
        echo -e "${YELLOW}⚠ BBR может быть недоступен в этом ядре${NC}"
        echo -e "${YELLOW}  Скрипт продолжит работу, но BBR может не активироваться${NC}"
    fi
    
    AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || echo "")
    if [[ $AVAILABLE_CC == *"bbr"* ]]; then
        echo -e "${GREEN}✓ BBR доступен: $AVAILABLE_CC${NC}"
    else
        echo -e "${YELLOW}⚠ Доступные алгоритмы: $AVAILABLE_CC${NC}"
    fi
    echo ""
    
# Шаг 4: Создание конфигурации sysctl
    echo -e "${YELLOW}[5/8] Создание конфигурации sysctl...${NC}"
    
    if [ -f /etc/sysctl.d/99-vps-tuning.conf ]; then
        cp /etc/sysctl.d/99-vps-tuning.conf /etc/sysctl.d/99-vps-tuning.conf.backup.$(date +%s)
        echo -e "${BLUE}ℹ Создана резервная копия существующей конфигурации${NC}"
    fi
    
    cat > /etc/sysctl.d/99-vps-tuning.conf <<EOF
# Конфигурация оптимизации сети VPS
# Создано: $(date)
# Интерфейс: $INTERFACE
# MTU: $OPTIMAL_MTU
# Виртуализация: $VIRT_TYPE

# --- BBR + FQ (Скорость и стабильность) ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Оптимизация TCP (Отзывчивость) ---
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_slow_start_after_idle = 0

# --- Буферы памяти (Пропускная способность) ---
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 33554432
net.ipv4.tcp_wmem = 4096 262144 33554432

# --- Режим невидимости (Блокировка ICMP) ---
net.ipv4.icmp_echo_ignore_all = 1
net.ipv6.icmp.echo_ignore_all = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
EOF
    
    echo -e "${GREEN}✓ Конфигурация создана: /etc/sysctl.d/99-vps-tuning.conf${NC}"
    echo ""
    
    echo -e "${GREEN}✓ Конфигурация создана: /etc/sysctl.d/99-vps-tuning.conf${NC}"
    echo ""
    
    # Шаг 5: Применение настроек sysctl
    echo -e "${YELLOW}[6/8] Применение настроек sysctl...${NC}"
    
    SYSCTL_OUTPUT=$(sysctl --system 2>&1)
    SYSCTL_EXIT=$?
    
    if [ $SYSCTL_EXIT -eq 0 ]; then
        echo -e "${GREEN}✓ Настройки sysctl успешно применены${NC}"
    else
        echo -e "${YELLOW}⚠ Sysctl сообщил о предупреждениях (обычно это нормально):${NC}"
        echo "$SYSCTL_OUTPUT" | grep -i "error\|fail" || echo "  Критических ошибок не обнаружено"
    fi
    echo ""
    
    # Шаг 6: Настройка FQ qdisc
    echo -e "${YELLOW}[7/8] Настройка FQ qdisc на $INTERFACE...${NC}"
    
    CURRENT_QDISC=$(tc qdisc show dev $INTERFACE | head -n1 | awk '{print $2}')
    echo "Текущий qdisc: $CURRENT_QDISC"
    
    if tc qdisc replace dev $INTERFACE root fq 2>/dev/null; then
        echo -e "${GREEN}✓ FQ qdisc активирован на $INTERFACE${NC}"
    else
        echo -e "${YELLOW}⚠ Не удалось установить FQ qdisc (может не поддерживаться)${NC}"
    fi
    echo ""
    
    # Шаг 7: Настройка автовосстановления (crontab)
    echo -e "${YELLOW}[8/8] Настройка автовосстановления (crontab)...${NC}"
    
    TEMP_CRON=$(mktemp)
    crontab -l > "$TEMP_CRON" 2>/dev/null || true
    
    # Удаление старых записей
    sed -i '/vps-tuning/d' "$TEMP_CRON"
    sed -i '/sysctl --system.*tc qdisc/d' "$TEMP_CRON"
    
    # Добавление новой записи (включая MTU)
    cat >> "$TEMP_CRON" <<EOF
# Оптимизация сети VPS - Автовосстановление
@reboot /bin/sleep 15 && /usr/sbin/ip link set dev $INTERFACE mtu $OPTIMAL_MTU && /usr/sbin/sysctl --system >/dev/null 2>&1 && /usr/sbin/tc qdisc replace dev $INTERFACE root fq >/dev/null 2>&1 # vps-tuning
EOF
    
    if crontab "$TEMP_CRON" 2>/dev/null; then
        echo -e "${GREEN}✓ Crontab настроен для автовосстановления после перезагрузки${NC}"
    else
        echo -e "${YELLOW}⚠ Не удалось настроить crontab (может потребоваться ручная настройка)${NC}"
    fi
    rm -f "$TEMP_CRON"
    echo ""
    
    # Финальная проверка
    echo -e "${BLUE}============================================${NC}"
    echo -e "${BLUE}        РЕЗУЛЬТАТЫ ПРОВЕРКИ${NC}"
    echo -e "${BLUE}============================================${NC}"
    echo ""
    
    BBR_ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    FQ_ACTIVE=$(tc qdisc show dev $INTERFACE 2>/dev/null | grep -o 'qdisc fq' | head -n1 || echo "")
    ICMP_STEALTH=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "unknown")
    QDISC_FULL=$(tc qdisc show dev $INTERFACE 2>/dev/null | head -n1 || echo "unknown")
    APPLIED_MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+' || echo "unknown")
    
    printf "%-30s %s\n" "Виртуализация:" "$VIRT_TYPE"
    printf "%-30s %s\n" "Интерфейс:" "$INTERFACE"
    printf "%-30s %s\n" "Обнаруженный MTU:" "$OPTIMAL_MTU"
    printf "%-30s %s\n" "Применённый MTU:" "$APPLIED_MTU"
    echo ""
    
    if [ "$BBR_ACTIVE" = "bbr" ]; then
        printf "%-30s ${GREEN}✓ %s${NC}\n" "Контроль перегрузки BBR:" "$BBR_ACTIVE"
    else
        printf "%-30s ${YELLOW}⚠ %s${NC}\n" "Контроль перегрузки BBR:" "$BBR_ACTIVE"
    fi
    
    if [ -n "$FQ_ACTIVE" ]; then
        printf "%-30s ${GREEN}✓ Активен${NC}\n" "FQ Qdisc:"
        echo "  └─ $QDISC_FULL"
    else
        printf "%-30s ${YELLOW}⚠ Не обнаружен${NC}\n" "FQ Qdisc:"
        echo "  └─ $QDISC_FULL"
    fi
    
    if [ "$ICMP_STEALTH" = "1" ]; then
        printf "%-30s ${GREEN}✓ Включён (значение: %s)${NC}\n" "Режим невидимости ICMP:" "$ICMP_STEALTH"
    else
        printf "%-30s ${YELLOW}⚠ %s${NC}\n" "Режим невидимости ICMP:" "$ICMP_STEALTH"
    fi
    
    # Проверка MTU
    if [ "$APPLIED_MTU" = "$OPTIMAL_MTU" ]; then
        printf "%-30s ${GREEN}✓ Совпадает${NC}\n" "Статус MTU:"
    else
        printf "%-30s ${YELLOW}⚠ Не совпадает${NC}\n" "Статус MTU:"
    fi
    
    echo ""
    echo -e "${BLUE}============================================${NC}"
    echo ""
    
    if [ "$BBR_ACTIVE" = "bbr" ] && [ -n "$FQ_ACTIVE" ] && [ "$APPLIED_MTU" = "$OPTIMAL_MTU" ]; then
        echo -e "${GREEN}✓✓✓ Оптимизация завершена успешно! ✓✓✓${NC}"
    else
        echo -e "${YELLOW}⚠ Оптимизация завершена с предупреждениями${NC}"
        echo -e "${YELLOW}  Проверьте результаты выше${NC}"
    fi
    
    echo ""
    echo -e "${BLUE}Следующие шаги:${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "1. ${YELLOW}Перезагрузка для проверки сохранения настроек:${NC}"
    echo -e "   ${GREEN}reboot${NC}"
    echo ""
    echo -e "2. ${YELLOW}После перезагрузки проверьте настройки:${NC}"
    echo -e "   ${GREEN}ip link show $INTERFACE | grep mtu${NC}"
    echo -e "   ${GREEN}tc qdisc show dev $INTERFACE${NC}"
    echo -e "   ${GREEN}sysctl net.ipv4.tcp_congestion_control${NC}"
    echo -e "   ${GREEN}sysctl net.ipv4.icmp_echo_ignore_all${NC}"
    echo ""
    echo -e "3. ${YELLOW}Просмотр полной конфигурации:${NC}"
    echo -e "   ${GREEN}cat /etc/sysctl.d/99-vps-tuning.conf${NC}"
    echo ""
    
    echo -e "${YELLOW}⚠ ВНИМАНИЕ: ICMP теперь заблокирован (режим невидимости)${NC}"
    echo "  Вы не сможете пропинговать этот сервер снаружи"
    echo -e "  Чтобы отключить: ${GREEN}sysctl -w net.ipv4.icmp_echo_ignore_all=0${NC}"
    echo ""
    
    if ls /etc/sysctl.d/99-vps-tuning.conf.backup.* >/dev/null 2>&1; then
        BACKUP_FILE=$(ls -t /etc/sysctl.d/99-vps-tuning.conf.backup.* 2>/dev/null | head -n1)
        echo -e "${BLUE}ℹ Резервная копия сохранена: $BACKUP_FILE${NC}"
        echo ""
    fi
    
    echo "Скрипт завершён: $(date)"
    echo ""
}

# Функция: Показать текущие настройки
show_current_settings() {
    echo ""
    echo -e "${CYAN}=== Текущие настройки системы ===${NC}"
    echo ""
    
    # Определить интерфейс
    detect_interface
    echo ""
    
    # MTU
    CURRENT_MTU=$(ip link show $INTERFACE | grep -oP 'mtu \K[0-9]+' || echo "неизвестно")
    echo -e "${BLUE}MTU:${NC} $CURRENT_MTU"
    
    # BBR
    BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
    if [ "$BBR_STATUS" = "bbr" ]; then
        echo -e "${BLUE}BBR:${NC} ${GREEN}✓ Активен${NC}"
    else
        echo -e "${BLUE}BBR:${NC} ${RED}✗ Не активен${NC} (текущий: $BBR_STATUS)"
    fi
    
    # FQ qdisc
    FQ_STATUS=$(tc qdisc show dev $INTERFACE 2>/dev/null | grep -o 'qdisc fq' | head -n1 || echo "")
    if [ -n "$FQ_STATUS" ]; then
        echo -e "${BLUE}FQ Qdisc:${NC} ${GREEN}✓ Активен${NC}"
    else
        CURRENT_QDISC=$(tc qdisc show dev $INTERFACE | head -n1 | awk '{print $2}')
        echo -e "${BLUE}FQ Qdisc:${NC} ${RED}✗ Не активен${NC} (текущий: $CURRENT_QDISC)"
    fi
    
    # ICMP Stealth
    ICMP_STATUS=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null || echo "неизвестно")
    if [ "$ICMP_STATUS" = "1" ]; then
        echo -e "${BLUE}ICMP Stealth:${NC} ${GREEN}✓ Включён${NC}"
    else
        echo -e "${BLUE}ICMP Stealth:${NC} ${RED}✗ Выключен${NC}"
    fi
    
    # Виртуализация
    VIRT=$(systemd-detect-virt 2>/dev/null || echo "неизвестно")
    echo -e "${BLUE}Виртуализация:${NC} $VIRT"
    
    echo ""
    read -p "Нажмите Enter для возврата в меню..."
}

# Главное меню
show_menu() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     Скрипт оптимизации сети VPS v2.2       ║${NC}"
    echo -e "${CYAN}║         Debian 11+ / Ubuntu 20.04+         ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Выберите действие:${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Автоматическая настройка (рекомендуется)"
    echo -e "  ${GREEN}2)${NC} Изменить MTU вручную"
    echo -e "  ${GREEN}3)${NC} Показать текущие настройки"
    echo -e "  ${GREEN}0)${NC} Выход"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Основной цикл программы
main() {
    while true; do
        show_menu
        read -p "Ваш выбор [0-3]: " choice
        
        case $choice in
            1)
                full_optimization
                echo ""
                read -p "Нажмите Enter для возврата в меню..."
                ;;
            2)
                detect_interface
                manual_set_mtu
                echo ""
                read -p "Нажмите Enter для возврата в меню..."
                ;;
            3)
                show_current_settings
                ;;
            0)
                echo ""
                echo -e "${GREEN}Спасибо за использование скрипта!${NC}"
                echo ""
                exit 0
                ;;
            *)
                echo ""
                echo -e "${RED}Неверный выбор. Пожалуйста, выберите 0-3.${NC}"
                sleep 2
                ;;
        esac
    done
}

# Запуск программы
main