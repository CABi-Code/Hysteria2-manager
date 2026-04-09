#!/bin/bash
# ================================================
# Автомиграция auth: password -> userpass
# ================================================

migrate_auth() {
    if grep -q 'type: password' "$CONFIG" 2>/dev/null; then
        echo "⚠️  Обнаружен старый тип auth: password"
        echo "   Переключаю на userpass..."
        sed -i 's/type: password/type: userpass/' "$CONFIG"
        sed -i '/^  password:/d' "$CONFIG"
        if ! grep -q '^  userpass:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
        echo "✅ Переключено на userpass."
    fi
    if ! grep -q '^  userpass:' "$CONFIG" 2>/dev/null; then
        if grep -q '^auth:' "$CONFIG"; then
            sed -i '/^auth:/a \  userpass:' "$CONFIG"
        fi
    fi
}
