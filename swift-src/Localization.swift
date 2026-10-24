import SwiftUI
import Combine

public enum AppLanguage: String, CaseIterable, Identifiable {
    case zhHans = "zh_Hans"
    case zhHant = "zh_Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case es = "es"
    case fr = "fr"
    case ru = "ru"
    case de = "de"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .es: return "Español"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .de: return "Deutsch"
        }
    }
}

public enum AppTheme: String, CaseIterable, Identifiable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var id: String { rawValue }

    public func displayName(using l10n: LocalizationManager) -> String {
        switch self {
        case .system: return l10n.t("theme_system")
        case .light: return l10n.t("theme_light")
        case .dark: return l10n.t("theme_dark")
        }
    }

    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

public final class LocalizationManager: ObservableObject {
    public static let shared = LocalizationManager()

    @Published public var currentLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(currentLanguage.rawValue, forKey: "macmic_language")
        }
    }

    @Published public var currentTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(currentTheme.rawValue, forKey: "macmic_theme")
            applyTheme()
        }
    }

    private init() {
        let initialLang: AppLanguage
        if let savedLangRaw = UserDefaults.standard.string(forKey: "macmic_language"),
           let lang = AppLanguage(rawValue: savedLangRaw) {
            initialLang = lang
        } else {
            // First time launch: detect from macOS system preferred languages
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            if preferred.hasPrefix("zh-hant") || preferred.hasPrefix("zh-tw") || preferred.hasPrefix("zh-hk") || preferred.hasPrefix("zh-mo") {
                initialLang = .zhHant
            } else if preferred.hasPrefix("zh") {
                initialLang = .zhHans
            } else if preferred.hasPrefix("ja") {
                initialLang = .ja
            } else if preferred.hasPrefix("ko") {
                initialLang = .ko
            } else if preferred.hasPrefix("es") {
                initialLang = .es
            } else if preferred.hasPrefix("fr") {
                initialLang = .fr
            } else if preferred.hasPrefix("ru") {
                initialLang = .ru
            } else if preferred.hasPrefix("de") {
                initialLang = .de
            } else {
                initialLang = .en
            }
            UserDefaults.standard.set(initialLang.rawValue, forKey: "macmic_language")
        }
        self.currentLanguage = initialLang

        let savedThemeRaw = UserDefaults.standard.string(forKey: "macmic_theme") ?? "system"
        self.currentTheme = AppTheme(rawValue: savedThemeRaw) ?? .system

        applyTheme()
    }

    public func applyTheme() {
        DispatchQueue.main.async {
            switch self.currentTheme {
            case .system:
                NSApp.appearance = nil
            case .light:
                NSApp.appearance = NSAppearance(named: .aqua)
            case .dark:
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    public func t(_ key: String) -> String {
        let dict = Self.allTranslations[currentLanguage] ?? Self.enStrings
        return dict[key] ?? Self.enStrings[key] ?? key
    }

    // MARK: - All Translations Table

    private static let allTranslations: [AppLanguage: [String: String]] = [
        .zhHans: zhHansStrings,
        .zhHant: zhHantStrings,
        .en: enStrings,
        .ja: jaStrings,
        .ko: koStrings,
        .es: esStrings,
        .fr: frStrings,
        .ru: ruStrings,
        .de: deStrings
    ]

    // 1. 简体中文
    private static let zhHansStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "偏好设置",
        "settings_title": "MacMic 设置",
        "done": "完成",
        "close": "关闭",
        "delete": "删除",
        "alert_title": "提示",
        "alert_ok": "好的",

        "transport_header": "连接方式",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi 直连",
        "phone_ip_label": "手机 IP:",
        "phone_ip_placeholder": "如 192.168.1.105",
        "history_ips": "历史 IP",
        "no_history_ip": "暂无历史 IP",

        "audio_routing_header": "音频输出目标",
        "virtual_mic_tag": " [虚拟麦克风]",
        "gain_label": "音量增益:",
        "mute_toggle": "一键静音",

        "vu_meter_header": "实时音频电平",

        "status_connected": "已连接",
        "status_connecting": "正在连接...",
        "status_error": "连接失败",
        "status_disconnected": "未连接",
        "btn_connect": "连 接",
        "btn_disconnect": "断开连接",

        "alert_no_adb_device": "未检测到 USB 连接的 Android 设备！\n请确保手机已开启【USB 调试】并用数据线连接 Mac。",
        "alert_adb_forward_failed": "ADB 端口转发失败！",
        "alert_empty_ip": "请输入手机 IP 地址！",

        "tab_display": "显示",
        "tab_general": "通用",
        "tab_about": "关于",

        "settings_display_section": "外观与语言",
        "settings_language": "界面语言",
        "settings_theme": "深浅模式",
        "theme_system": "跟随系统",
        "theme_light": "浅色",
        "theme_dark": "深色",

        "settings_general_section": "系统启动与后台",
        "settings_launch_at_login": "开机自启动",
        "settings_hide_dock": "隐藏 Dock 图标",

        "about_version": "版本",
        "about_project_url": "项目主页",
        "about_author": "作者",
        "about_email": "联系邮箱",
        "about_open_github": "访问 GitHub 仓库",
        "about_send_email": "发送邮件反馈",

        "menu_status_connected": "● 状态: 已连接",
        "menu_status_disconnected": "● 状态: 未连接",
        "menu_action_connect": "连接",
        "menu_action_disconnect": "断开连接",
        "menu_open_panel": "打开主面板",
        "menu_settings": "偏好设置...",
        "menu_quit": "退出 MacMic",

        "adb_device_label": "ADB 设备",
        "adb_no_devices": "未发现已授权的 ADB 设备",
        "adb_refresh": "刷新 ADB 设备",
        "usb_hint": "通过 USB 调试连接所选 Android 设备，自动转发端口 8125",
        "wifi_direct_hint": "请先连接到手机创建的 Wi-Fi 直连热点",
        "refresh_devices": "刷新设备列表",
        "recommended_tag": "推荐",
        "blackhole_missing": "未检测到 BlackHole 虚拟声卡",
        "blackhole_missing_detail": "请安装 BlackHole 2ch 作为虚拟麦克风",
        "unmute": "取消静音",
        "stats_packets": "数据包",
        "stats_received": "已接收",
        "level_idle": "无信号",
        "status_ready_hint": "选择连接方式后点击“连接”",
        "settings_appearance_footer": "主题与语言更改立即生效"
    ]

    // 2. 繁體中文
    private static let zhHantStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "偏好設定",
        "settings_title": "MacMic 設定",
        "done": "完成",
        "close": "關閉",
        "delete": "刪除",
        "alert_title": "提示",
        "alert_ok": "好",

        "transport_header": "連線方式",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi 直連",
        "phone_ip_label": "手機 IP:",
        "phone_ip_placeholder": "如 192.168.1.105",
        "history_ips": "歷史 IP",
        "no_history_ip": "暫無歷史 IP",

        "audio_routing_header": "音訊輸出目標",
        "virtual_mic_tag": " [虛擬麥克風]",
        "gain_label": "音量增益:",
        "mute_toggle": "一鍵靜音",

        "vu_meter_header": "即時音訊電平",

        "status_connected": "已連線",
        "status_connecting": "正在連線...",
        "status_error": "連線失敗",
        "status_disconnected": "未連線",
        "btn_connect": "連 線",
        "btn_disconnect": "中斷連線",

        "alert_no_adb_device": "未檢測到 USB 連接的 Android 裝置！\n請確保手機已開啟【USB 調試】並用傳輸線連接 Mac。",
        "alert_adb_forward_failed": "ADB 連接埠轉發失敗！",
        "alert_empty_ip": "請輸入手機 IP 位址！",

        "tab_display": "顯示",
        "tab_general": "一般",
        "tab_about": "關於",

        "settings_display_section": "外觀與語言",
        "settings_language": "介面語言",
        "settings_theme": "深淺模式",
        "theme_system": "跟隨系統",
        "theme_light": "淺色",
        "theme_dark": "深色",

        "settings_general_section": "系統啟動與背景",
        "settings_launch_at_login": "開機自啟動",
        "settings_hide_dock": "隱藏 Dock 圖示",

        "about_version": "版本",
        "about_project_url": "專案首頁",
        "about_author": "作者",
        "about_email": "聯絡信箱",
        "about_open_github": "瀏覽 GitHub 倉庫",
        "about_send_email": "發送郵件反饋",

        "menu_status_connected": "● 狀態: 已連線",
        "menu_status_disconnected": "● 狀態: 未連線",
        "menu_action_connect": "連線",
        "menu_action_disconnect": "中斷連線",
        "menu_open_panel": "開啟主面板",
        "menu_settings": "偏好設定...",
        "menu_quit": "結束 MacMic",

        "adb_device_label": "ADB 裝置",
        "adb_no_devices": "未發現已授權的 ADB 裝置",
        "adb_refresh": "重新整理 ADB 裝置",
        "usb_hint": "透過 USB 偵錯連接所選 Android 裝置，自動轉發連接埠 8125",
        "wifi_direct_hint": "請先連線到手機建立的 Wi-Fi 直連熱點",
        "refresh_devices": "重新整理裝置列表",
        "recommended_tag": "推薦",
        "blackhole_missing": "未偵測到 BlackHole 虛擬音效卡",
        "blackhole_missing_detail": "請安裝 BlackHole 2ch 作為虛擬麥克風",
        "unmute": "取消靜音",
        "stats_packets": "封包",
        "stats_received": "已接收",
        "level_idle": "無訊號",
        "status_ready_hint": "選擇連線方式後點擊「連線」",
        "settings_appearance_footer": "主題與語言變更立即生效"
    ]

    // 3. English
    private static let enStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "Settings",
        "settings_title": "MacMic Settings",
        "done": "Done",
        "close": "Close",
        "delete": "Delete",
        "alert_title": "Notice",
        "alert_ok": "OK",

        "transport_header": "Transport Mode",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "Phone IP:",
        "phone_ip_placeholder": "e.g. 192.168.1.105",
        "history_ips": "History IPs",
        "no_history_ip": "No history IPs",

        "audio_routing_header": "Audio Output Target",
        "virtual_mic_tag": " [Virtual Mic]",
        "gain_label": "Volume Gain:",
        "mute_toggle": "Mute Microphone",

        "vu_meter_header": "Audio Level (VU Meter)",

        "status_connected": "Connected",
        "status_connecting": "Connecting...",
        "status_error": "Connection Failed",
        "status_disconnected": "Disconnected",
        "btn_connect": "Connect",
        "btn_disconnect": "Disconnect",

        "alert_no_adb_device": "No USB-connected Android device detected!\nPlease ensure \"USB Debugging\" is enabled and connected via cable.",
        "alert_adb_forward_failed": "ADB port forwarding failed!",
        "alert_empty_ip": "Please enter phone IP address!",

        "tab_display": "Display",
        "tab_general": "General",
        "tab_about": "About",

        "settings_display_section": "Appearance & Language",
        "settings_language": "Language",
        "settings_theme": "Theme",
        "theme_system": "Follow System",
        "theme_light": "Light",
        "theme_dark": "Dark",

        "settings_general_section": "Startup & Background",
        "settings_launch_at_login": "Launch at Login",
        "settings_hide_dock": "Hide Dock Icon",

        "about_version": "Version",
        "about_project_url": "Project URL",
        "about_author": "Author",
        "about_email": "Email",
        "about_open_github": "Open GitHub Repo",
        "about_send_email": "Send Feedback Email",

        "menu_status_connected": "● Status: Connected",
        "menu_status_disconnected": "● Status: Disconnected",
        "menu_action_connect": "Connect",
        "menu_action_disconnect": "Disconnect",
        "menu_open_panel": "Open Main Panel",
        "menu_settings": "Settings...",
        "menu_quit": "Quit MacMic",

        "adb_device_label": "ADB device",
        "adb_no_devices": "No authorized ADB devices found",
        "adb_refresh": "Refresh ADB devices",
        "usb_hint": "Connects the selected Android device over USB debugging and forwards port 8125 automatically",
        "wifi_direct_hint": "Join the Wi-Fi Direct hotspot created by your phone first",
        "refresh_devices": "Refresh devices",
        "recommended_tag": "Recommended",
        "blackhole_missing": "BlackHole virtual audio device not found",
        "blackhole_missing_detail": "Install BlackHole 2ch to use it as a virtual mic",
        "unmute": "Unmute",
        "stats_packets": "Packets",
        "stats_received": "Received",
        "level_idle": "No signal",
        "status_ready_hint": "Choose a transport, then click Connect",
        "settings_appearance_footer": "Theme and language changes apply immediately"
    ]

    // 4. 日本語
    private static let jaStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "設定",
        "settings_title": "MacMic 設定",
        "done": "完了",
        "close": "閉じる",
        "delete": "削除",
        "alert_title": "お知らせ",
        "alert_ok": "了解",

        "transport_header": "接続モード",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "スマホ IP:",
        "phone_ip_placeholder": "例: 192.168.1.105",
        "history_ips": "履歴 IP",
        "no_history_ip": "履歴なし",

        "audio_routing_header": "オーディオ出力先",
        "virtual_mic_tag": " [仮想マイク]",
        "gain_label": "音量ゲイン:",
        "mute_toggle": "ミュート",

        "vu_meter_header": "リアルタイム音声レベル",

        "status_connected": "接続済み",
        "status_connecting": "接続中...",
        "status_error": "接続失敗",
        "status_disconnected": "未接続",
        "btn_connect": "接 続",
        "btn_disconnect": "切 断",

        "alert_no_adb_device": "USB接続されたAndroidデバイスが見つかりません！\n「USBデバッグ」を有効にしてケーブルで接続してください。",
        "alert_adb_forward_failed": "ADBポート転送に失敗しました！",
        "alert_empty_ip": "スマホのIPアドレスを入力してください！",

        "tab_display": "表示",
        "tab_general": "一般",
        "tab_about": "情報",

        "settings_display_section": "外観と言語",
        "settings_language": "言語設定",
        "settings_theme": "テーマ",
        "theme_system": "システムに従う",
        "theme_light": "ライト",
        "theme_dark": "ダーク",

        "settings_general_section": "起動とバックグラウンド",
        "settings_launch_at_login": "ログイン時に自動起動",
        "settings_hide_dock": "Dockアイコンを隠す",

        "about_version": "バージョン",
        "about_project_url": "プロジェクトURL",
        "about_author": "作者",
        "about_email": "連絡先メール",
        "about_open_github": "GitHubリポジトリを開く",
        "about_send_email": "フィードバックメール送信",

        "menu_status_connected": "● 状態: 接続済み",
        "menu_status_disconnected": "● 状態: 未接続",
        "menu_action_connect": "接続",
        "menu_action_disconnect": "切断",
        "menu_open_panel": "メイン画面を開く",
        "menu_settings": "設定...",
        "menu_quit": "MacMicを終了",

        "usb_hint": "USB デバッグで Android に接続し、ポート 8125 を自動転送します",
        "wifi_direct_hint": "先にスマートフォンの Wi-Fi Direct ホットスポットに接続してください",
        "refresh_devices": "デバイスを更新",
        "recommended_tag": "推奨",
        "blackhole_missing": "BlackHole 仮想オーディオデバイスが見つかりません",
        "blackhole_missing_detail": "仮想マイクとして BlackHole 2ch をインストールしてください",
        "unmute": "ミュート解除",
        "stats_packets": "パケット",
        "stats_received": "受信済み",
        "level_idle": "信号なし",
        "status_ready_hint": "接続方法を選んで「接続」をクリック",
        "settings_appearance_footer": "テーマと言語の変更はすぐに反映されます"
    ]

    // 5. 한국어
    private static let koStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "환경설정",
        "settings_title": "MacMic 설정",
        "done": "완료",
        "close": "닫기",
        "delete": "삭제",
        "alert_title": "알림",
        "alert_ok": "확인",

        "transport_header": "연결 방식",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "휴대폰 IP:",
        "phone_ip_placeholder": "예: 192.168.1.105",
        "history_ips": "이전 IP",
        "no_history_ip": "기록된 IP 없음",

        "audio_routing_header": "오디오 출력 대상",
        "virtual_mic_tag": " [가상 마이크]",
        "gain_label": "볼륨 게인:",
        "mute_toggle": "음소거",

        "vu_meter_header": "실시간 오디오 레벨",

        "status_connected": "연결됨",
        "status_connecting": "연결 중...",
        "status_error": "연결 실패",
        "status_disconnected": "연결 안 됨",
        "btn_connect": "연 결",
        "btn_disconnect": "연결 해제",

        "alert_no_adb_device": "USB로 연결된 Android 기기를 찾을 수 없습니다!\n\"USB 디버깅\"이 켜져 있고 케이블로 연결되었는지 확인하세요.",
        "alert_adb_forward_failed": "ADB 포트 포워딩 실패!",
        "alert_empty_ip": "휴대폰 IP 주소를 입력하세요!",

        "tab_display": "디스플레이",
        "tab_general": "일반",
        "tab_about": "정보",

        "settings_display_section": "모양 및 언어",
        "settings_language": "언어 설정",
        "settings_theme": "테마 모드",
        "theme_system": "시스템 설정 따름",
        "theme_light": "라이트",
        "theme_dark": "다크",

        "settings_general_section": "시작 및 백그라운드",
        "settings_launch_at_login": "로그인 시 자동 실행",
        "settings_hide_dock": "Dock 아이콘 숨기기",

        "about_version": "버전",
        "about_project_url": "프로젝트 URL",
        "about_author": "개발자",
        "about_email": "이메일",
        "about_open_github": "GitHub 저장소 열기",
        "about_send_email": "피드백 이메일 보내기",

        "menu_status_connected": "● 상태: 연결됨",
        "menu_status_disconnected": "● 상태: 연결 안 됨",
        "menu_action_connect": "연결",
        "menu_action_disconnect": "연결 해제",
        "menu_open_panel": "메인 패널 열기",
        "menu_settings": "환경설정...",
        "menu_quit": "MacMic 종료",

        "usb_hint": "USB 디버깅으로 Android에 연결하고 포트 8125를 자동 포워딩합니다",
        "wifi_direct_hint": "먼저 휴대폰의 Wi-Fi Direct 핫스팟에 연결하세요",
        "refresh_devices": "장치 새로 고침",
        "recommended_tag": "권장",
        "blackhole_missing": "BlackHole 가상 오디오 장치를 찾을 수 없습니다",
        "blackhole_missing_detail": "가상 마이크로 사용할 BlackHole 2ch를 설치하세요",
        "unmute": "음소거 해제",
        "stats_packets": "패킷",
        "stats_received": "수신됨",
        "level_idle": "신호 없음",
        "status_ready_hint": "연결 방식을 선택한 후 연결을 클릭하세요",
        "settings_appearance_footer": "테마와 언어 변경은 즉시 적용됩니다"
    ]

    // 6. Español
    private static let esStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "Preferencias",
        "settings_title": "Ajustes de MacMic",
        "done": "Listo",
        "close": "Cerrar",
        "delete": "Eliminar",
        "alert_title": "Aviso",
        "alert_ok": "Aceptar",

        "transport_header": "Modo de conexión",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "IP del teléfono:",
        "phone_ip_placeholder": "ej. 192.168.1.105",
        "history_ips": "Historial de IPs",
        "no_history_ip": "Sin historial",

        "audio_routing_header": "Dispositivo de salida",
        "virtual_mic_tag": " [Micrófono virtual]",
        "gain_label": "Ganancia de volumen:",
        "mute_toggle": "Silenciar micrófono",

        "vu_meter_header": "Nivel de audio (VU Metro)",

        "status_connected": "Conectado",
        "status_connecting": "Conectando...",
        "status_error": "Error de conexión",
        "status_disconnected": "Desconectado",
        "btn_connect": "Conectar",
        "btn_disconnect": "Desconectar",

        "alert_no_adb_device": "¡No se detectó ningún dispositivo Android conectado por USB!\nAsegúrese de que la \"Depuración USB\" esté habilitada y conectada por cable.",
        "alert_adb_forward_failed": "¡Error en el reenvío de puertos ADB!",
        "alert_empty_ip": "¡Por favor ingrese la dirección IP del teléfono!",

        "tab_display": "Pantalla",
        "tab_general": "General",
        "tab_about": "Acerca de",

        "settings_display_section": "Apariencia e idioma",
        "settings_language": "Idioma",
        "settings_theme": "Tema",
        "theme_system": "Seguir sistema",
        "theme_light": "Claro",
        "theme_dark": "Oscuro",

        "settings_general_section": "Inicio y segundo plano",
        "settings_launch_at_login": "Iniciar al encender",
        "settings_hide_dock": "Ocultar icono del Dock",

        "about_version": "Versión",
        "about_project_url": "URL del proyecto",
        "about_author": "Autor",
        "about_email": "Correo de contacto",
        "about_open_github": "Abrir repositorio GitHub",
        "about_send_email": "Enviar comentarios por correo",

        "menu_status_connected": "● Estado: Conectado",
        "menu_status_disconnected": "● Estado: Desconectado",
        "menu_action_connect": "Conectar",
        "menu_action_disconnect": "Desconectar",
        "menu_open_panel": "Abrir panel principal",
        "menu_settings": "Preferencias...",
        "menu_quit": "Salir de MacMic",

        "usb_hint": "Conecta Android mediante depuración USB y reenvía el puerto 8125 automáticamente",
        "wifi_direct_hint": "Conéctate primero al punto Wi-Fi Direct creado por el teléfono",
        "refresh_devices": "Actualizar dispositivos",
        "recommended_tag": "Recomendado",
        "blackhole_missing": "No se encontró el dispositivo virtual BlackHole",
        "blackhole_missing_detail": "Instala BlackHole 2ch para usarlo como micrófono virtual",
        "unmute": "Activar sonido",
        "stats_packets": "Paquetes",
        "stats_received": "Recibido",
        "level_idle": "Sin señal",
        "status_ready_hint": "Elige un transporte y pulsa Conectar",
        "settings_appearance_footer": "Los cambios de tema e idioma se aplican al instante"
    ]

    // 7. Français
    private static let frStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "Préférences",
        "settings_title": "Réglages de MacMic",
        "done": "Terminé",
        "close": "Fermer",
        "delete": "Supprimer",
        "alert_title": "Information",
        "alert_ok": "D'accord",

        "transport_header": "Mode de connexion",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "IP du téléphone :",
        "phone_ip_placeholder": "ex. 192.168.1.105",
        "history_ips": "Historique des IP",
        "no_history_ip": "Aucun historique",

        "audio_routing_header": "Périphérique de sortie",
        "virtual_mic_tag": " [Micro virtuel]",
        "gain_label": "Gain de volume :",
        "mute_toggle": "Couper le micro",

        "vu_meter_header": "Niveau audio (VU-mètre)",

        "status_connected": "Connecté",
        "status_connecting": "Connexion...",
        "status_error": "Échec de connexion",
        "status_disconnected": "Déconnecté",
        "btn_connect": "Connecter",
        "btn_disconnect": "Déconnecter",

        "alert_no_adb_device": "Aucun appareil Android connecté par USB détecté !\nVeuillez vous assurer que le « Débogage USB » est activé et connecté par câble.",
        "alert_adb_forward_failed": "Échec de redirection de port ADB !",
        "alert_empty_ip": "Veuillez saisir l'adresse IP du téléphone !",

        "tab_display": "Affichage",
        "tab_general": "Général",
        "tab_about": "À propos",

        "settings_display_section": "Apparence et langue",
        "settings_language": "Langue",
        "settings_theme": "Thème",
        "theme_system": "Suivre le système",
        "theme_light": "Clair",
        "theme_dark": "Sombre",

        "settings_general_section": "Démarrage et arrière-plan",
        "settings_launch_at_login": "Lancer au démarrage",
        "settings_hide_dock": "Masquer l'icône du Dock",

        "about_version": "Version",
        "about_project_url": "Page du projet",
        "about_author": "Auteur",
        "about_email": "Courriel",
        "about_open_github": "Ouvrir le dépôt GitHub",
        "about_send_email": "Envoyer des commentaires",

        "menu_status_connected": "● État : Connecté",
        "menu_status_disconnected": "● État : Déconnecté",
        "menu_action_connect": "Connecter",
        "menu_action_disconnect": "Déconnecter",
        "menu_open_panel": "Ouvrir le panneau principal",
        "menu_settings": "Préférences...",
        "menu_quit": "Quitter MacMic",

        "usb_hint": "Connecte Android via le débogage USB et redirige automatiquement le port 8125",
        "wifi_direct_hint": "Rejoignez d'abord le point d'accès Wi-Fi Direct du téléphone",
        "refresh_devices": "Actualiser les appareils",
        "recommended_tag": "Recommandé",
        "blackhole_missing": "Périphérique virtuel BlackHole introuvable",
        "blackhole_missing_detail": "Installez BlackHole 2ch pour l'utiliser comme micro virtuel",
        "unmute": "Réactiver le son",
        "stats_packets": "Paquets",
        "stats_received": "Reçu",
        "level_idle": "Aucun signal",
        "status_ready_hint": "Choisissez un transport, puis cliquez sur Connecter",
        "settings_appearance_footer": "Les changements de thème et de langue sont immédiats"
    ]

    // 8. Русский
    private static let ruStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "Настройки",
        "settings_title": "Настройки MacMic",
        "done": "Готово",
        "close": "Закрыть",
        "delete": "Удалить",
        "alert_title": "Уведомление",
        "alert_ok": "ОК",

        "transport_header": "Режим подключения",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "IP телефона:",
        "phone_ip_placeholder": "напр. 192.168.1.105",
        "history_ips": "История IP",
        "no_history_ip": "Нет истории IP",

        "audio_routing_header": "Устройство вывода",
        "virtual_mic_tag": " [Виртуальный микрофон]",
        "gain_label": "Усиление звука:",
        "mute_toggle": "Выключить микрофон",

        "vu_meter_header": "Уровень звука (VU метр)",

        "status_connected": "Подключено",
        "status_connecting": "Подключение...",
        "status_error": "Сбой подключения",
        "status_disconnected": "Отключено",
        "btn_connect": "Подключить",
        "btn_disconnect": "Отключить",

        "alert_no_adb_device": "Android-устройство, подключенное по USB, не обнаружено!\nУбедитесь, что включена «Отладка по USB» и кабель подключен.",
        "alert_adb_forward_failed": "Сбой перенаправления порта ADB!",
        "alert_empty_ip": "Пожалуйста, введите IP-адрес телефона!",

        "tab_display": "Вид",
        "tab_general": "Основные",
        "tab_about": "О программе",

        "settings_display_section": "Внешний вид и язык",
        "settings_language": "Язык интерфейса",
        "settings_theme": "Тема оформления",
        "theme_system": "Как в системе",
        "theme_light": "Светлая",
        "theme_dark": "Тёмная",

        "settings_general_section": "Запуск и фон",
        "settings_launch_at_login": "Автозапуск при входе",
        "settings_hide_dock": "Скрыть значок в Dock",

        "about_version": "Версия",
        "about_project_url": "Сайт проекта",
        "about_author": "Автор",
        "about_email": "Эл. почта",
        "about_open_github": "Открыть репозиторий GitHub",
        "about_send_email": "Отправить отзыв по почте",

        "menu_status_connected": "● Статус: Подключено",
        "menu_status_disconnected": "● Статус: Отключено",
        "menu_action_connect": "Подключить",
        "menu_action_disconnect": "Отключить",
        "menu_open_panel": "Открыть главное окно",
        "menu_settings": "Настройки...",
        "menu_quit": "Выйти из MacMic",

        "usb_hint": "Подключение Android через отладку по USB с автоматической переадресацией порта 8125",
        "wifi_direct_hint": "Сначала подключитесь к точке Wi-Fi Direct, созданной телефоном",
        "refresh_devices": "Обновить устройства",
        "recommended_tag": "Рекомендуется",
        "blackhole_missing": "Виртуальное устройство BlackHole не найдено",
        "blackhole_missing_detail": "Установите BlackHole 2ch для использования в качестве виртуального микрофона",
        "unmute": "Включить звук",
        "stats_packets": "Пакеты",
        "stats_received": "Получено",
        "level_idle": "Нет сигнала",
        "status_ready_hint": "Выберите способ подключения и нажмите «Подключить»",
        "settings_appearance_footer": "Изменения темы и языка применяются сразу"
    ]

    // 9. Deutsch
    private static let deStrings: [String: String] = [
        "app_title": "MacMic",
        "settings": "Einstellungen",
        "settings_title": "MacMic-Einstellungen",
        "done": "Fertig",
        "close": "Schließen",
        "delete": "Löschen",
        "alert_title": "Hinweis",
        "alert_ok": "OK",

        "transport_header": "Verbindungsmodus",
        "transport_wifi": "Wi-Fi",
        "transport_usb": "USB (ADB)",
        "transport_wifi_direct": "Wi-Fi Direct",
        "phone_ip_label": "Telefon-IP:",
        "phone_ip_placeholder": "z.B. 192.168.1.105",
        "history_ips": "IP-Verlauf",
        "no_history_ip": "Kein IP-Verlauf",

        "audio_routing_header": "Audioausgabeziel",
        "virtual_mic_tag": " [Virtuelles Mikrofon]",
        "gain_label": "Lautstärkeverstärkung:",
        "mute_toggle": "Stummschalten",

        "vu_meter_header": "Echtzeit-Audiopegel",

        "status_connected": "Verbunden",
        "status_connecting": "Verbinde...",
        "status_error": "Verbindung fehlgeschlagen",
        "status_disconnected": "Getrennt",
        "btn_connect": "Verbinden",
        "btn_disconnect": "Trennen",

        "alert_no_adb_device": "Kein über USB verbundenes Android-Gerät gefunden!\nBitte stellen Sie sicher, dass \"USB-Debugging\" aktiviert und das Gerät angeschlossen ist.",
        "alert_adb_forward_failed": "ADB-Portweiterleitung fehlgeschlagen!",
        "alert_empty_ip": "Bitte geben Sie die IP-Adresse des Telefons ein!",

        "tab_display": "Anzeige",
        "tab_general": "Allgemein",
        "tab_about": "Über",

        "settings_display_section": "Erscheinungsbild & Sprache",
        "settings_language": "Sprache",
        "settings_theme": "Design",
        "theme_system": "Systemstandard",
        "theme_light": "Hell",
        "theme_dark": "Dunkel",

        "settings_general_section": "Start & Hintergrund",
        "settings_launch_at_login": "Beim Login starten",
        "settings_hide_dock": "Dock-Symbol ausblenden",

        "about_version": "Version",
        "about_project_url": "Projekt-Webseite",
        "about_author": "Autor",
        "about_email": "Kontakt-E-Mail",
        "about_open_github": "GitHub-Repository öffnen",
        "about_send_email": "Feedback-E-Mail senden",

        "menu_status_connected": "● Status: Verbunden",
        "menu_status_disconnected": "● Status: Getrennt",
        "menu_action_connect": "Verbinden",
        "menu_action_disconnect": "Trennen",
        "menu_open_panel": "Hauptfenster öffnen",
        "menu_settings": "Einstellungen...",
        "menu_quit": "MacMic beenden",

        "usb_hint": "Verbindet Android per USB-Debugging und leitet Port 8125 automatisch weiter",
        "wifi_direct_hint": "Verbinde dich zuerst mit dem Wi-Fi-Direct-Hotspot des Telefons",
        "refresh_devices": "Geräte aktualisieren",
        "recommended_tag": "Empfohlen",
        "blackhole_missing": "Virtuelles BlackHole-Gerät nicht gefunden",
        "blackhole_missing_detail": "Installiere BlackHole 2ch, um es als virtuelles Mikrofon zu nutzen",
        "unmute": "Stummschaltung aufheben",
        "stats_packets": "Pakete",
        "stats_received": "Empfangen",
        "level_idle": "Kein Signal",
        "status_ready_hint": "Verbindungsart wählen und auf Verbinden klicken",
        "settings_appearance_footer": "Design- und Sprachänderungen gelten sofort"
    ]
}
