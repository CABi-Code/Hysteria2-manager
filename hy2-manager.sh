<?php

namespace App\Repository\ServerPingRepository;

trait StatusTrait
{
    /**
     * Сохранить статус сервера
     * Эффективно: не дублирует данные если они не изменились
     */
    public function saveStatus(int $itemId, array $data): bool
    {
        // Получаем последний статус
        $last = $this->getLastStatus($itemId);
        
        // Проверяем, изменились ли данные
        $hasChanged = $this->hasStatusChanged($last, $data);
        
        // Обновляем текущий статус в user_folder_items
        $this->updateItemStatus($itemId, $data);
        
        // Записываем в историю
        if ($hasChanged) {
            // Полная запись с новыми данными
            $this->insertHistoryRecord($itemId, $data, false);
        } else {
            // Только отметка времени (данные те же)
            $this->insertHistoryRecord($itemId, $data, true);
        }
        
        return true;
    }
    
    /**
     * Получить последний статус сервера
     */
    public function getLastStatus(int $itemId): ?array
    {
        return $this->db->fetchOne(
            "SELECT * FROM server_ping_history 
             WHERE item_id = ? AND is_same_as_previous = 0 
             ORDER BY checked_at DESC LIMIT 1",
            [$itemId]
        );
    }
    
    /**
     * Получить текущий статус сервера из items
     */
    public function getCurrentStatus(int $itemId): ?array
    {
        $item = $this->db->fetchOne(
            "SELECT settings FROM user_folder_items WHERE id = ?",
            [$itemId]
        );
        
        if (!$item || !$item['settings']) return null;
        
        $settings = json_decode($item['settings'], true);
        return $settings['status'] ?? null;
    }
    
    /**
     * Проверить, изменился ли статус
     */
    private function hasStatusChanged(?array $last, array $current): bool
    {
        if (!$last) return true;
        
        // Сравниваем ключевые поля
        if ((bool)$last['is_online'] !== (bool)$current['online']) return true;
        if ((int)$last['players_online'] !== (int)$current['players_online']) return true;
        if ((int)$last['players_max'] !== (int)$current['players_max']) return true;
        
        // Сравниваем список игроков
        $lastPlayers = $last['players_sample'] ? json_decode($last['players_sample'], true) : [];
        $currentPlayers = $current['players_sample'] ?? [];
        
        $lastNames = array_column($lastPlayers, 'name');
        $currentNames = array_column($currentPlayers, 'name');
        
        sort($lastNames);
        sort($currentNames);
        
        if ($lastNames !== $currentNames) return true;
        
        return false;
    }
    
    /**
     * Обновить статус в настройках элемента
     */
    private function updateItemStatus(int $itemId, array $data): void
    {
        $item = $this->db->fetchOne(
            "SELECT settings FROM user_folder_items WHERE id = ?",
            [$itemId]
        );
        
        if (!$item) return;
        
        $settings = $item['settings'] ? json_decode($item['settings'], true) : [];
        $settings['status'] = [
            'online' => $data['online'],
            'players_online' => $data['players_online'],
            'players_max' => $data['players_max'],
            'version' => $data['version'] ?? null,
            'last_check' => date('Y-m-d H:i:s')
        ];
        
        $this->db->execute(
            "UPDATE user_folder_items SET settings = ? WHERE id = ?",
            [json_encode($settings), $itemId]
        );
    }
    
    /**
     * Вставить запись в историю
     */
    private function insertHistoryRecord(int $itemId, array $data, bool $isSame): void
    {
        $this->db->execute(
            "INSERT INTO server_ping_history 
             (item_id, is_online, players_online, players_max, players_sample, version, source, is_same_as_previous, checked_at)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW())",
            [
                $itemId,
                $data['online'] ? 1 : 0,
                $data['players_online'],
                $data['players_max'],
                json_encode($data['players_sample'] ?? []),
                $data['version'] ?? null,
                $data['source'] ?? 'unknown',
                $isSame ? 1 : 0
            ]
        );
    }
}
