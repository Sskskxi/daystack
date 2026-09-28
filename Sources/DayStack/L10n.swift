import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, en, ko
    var id: String { rawValue }
}

/// English strings are the keys; Korean comes from the table below. A hand-rolled table (instead of
/// .strings files) lets the Language setting switch instantly without relaunching.
enum L10n {
    static var language = AppLanguage.auto

    static var isKorean: Bool {
        switch language {
        case .ko: return true
        case .en: return false
        case .auto: return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }
    }

    static var locale: Locale {
        if isKorean { return Locale(identifier: "ko_KR") }
        return language == .en ? Locale(identifier: "en_US") : Locale.current
    }

    static let ko: [String: String] = [
        // Calendar
        "Today": "오늘",
        "Last %d weeks": "최근 %d주",
        "Friends": "친구",
        "Month view": "월 보기",
        "Stacked weeks view": "주간 스택 보기",
        "Settings": "설정",
        "%d done": "%d개 완료",
        "Less": "적음",
        "More": "많음",
        "Nothing planned today.": "오늘은 계획이 없어요.",
        "Unfinished earlier": "이전에 못 끝낸 일",
        "Open day": "이 날 열기",
        "Open this day": "이 날 열기",
        "%@: %d done": "%@: %d개 완료",
        "1 to-do": "할 일 1개",
        "%d to-dos": "할 일 %d개",
        // Day
        "Add a to-do…": "할 일 추가…",
        "Add": "추가",
        "Nothing yet. Type above and press ⏎.": "아직 없어요. 위에 입력하고 ⏎를 누르세요.",
        "Edit": "수정",
        "Delete": "삭제",
        // Notice bar
        "DayStack %@ is available": "DayStack %@ 업데이트가 있어요",
        "Update": "업데이트",
        // Friends
        "Refresh": "새로 고침",
        "Your name": "내 이름",
        "Name": "이름",
        "Share your to-dos with friends through a shared iCloud Drive folder.": "공유 iCloud Drive 폴더로 친구와 할 일을 함께 봐요.",
        "Create a group": "그룹 만들기",
        "Invite code": "초대 코드",
        "Join": "참여",
        "To join, first accept your friend's iCloud folder invite, then enter their code.": "참여하려면 먼저 친구의 iCloud 폴더 초대를 수락한 뒤 코드를 입력하세요.",
        "Copy code": "코드 복사",
        "Share folder…": "폴더 공유…",
        "To invite: in Finder, right-click the DayStack folder → Share → invite your friend. Then send them the code.": "초대하려면: Finder에서 DayStack 폴더를 오른쪽 클릭 → 공유 → 친구를 초대한 뒤, 코드를 보내주세요.",
        "No friends have joined yet.\nYour to-dos are shared. Friends appear here once they join with code %@.": "아직 참여한 친구가 없어요.\n내 할 일은 공유되고 있어요. 친구가 코드 %@로 참여하면 여기에 나타나요.",
        "Leave group": "그룹 나가기",
        "Today %d/%d · %@": "오늘 %d/%d · %@",
        "No to-dos this day.": "이 날은 할 일이 없어요.",
        // Sync messages
        "Couldn't create the group folder: %@": "그룹 폴더를 만들지 못했어요: %@",
        "Looking for the shared folder…": "공유 폴더를 찾는 중…",
        "No shared folder with code %@ found. Accept your friend's iCloud folder invite first, then try again.": "코드 %@의 공유 폴더를 찾지 못했어요. 먼저 친구의 iCloud 폴더 초대를 수락한 뒤 다시 시도하세요.",
        "The shared group folder is gone (deleted or no longer shared). Leave the group and join again.": "공유 그룹 폴더가 사라졌어요 (삭제되었거나 공유가 해제됨). 그룹을 나갔다가 다시 참여하세요.",
        "Couldn't save to the shared folder: %@": "공유 폴더에 저장하지 못했어요: %@",
        "iCloud Drive is off. Turn it on in System Settings → Apple Account → iCloud → iCloud Drive.": "iCloud Drive가 꺼져 있어요. 시스템 설정 → Apple 계정 → iCloud → iCloud Drive에서 켜주세요.",
        "Updates only work when running DayStack.app.": "업데이트는 DayStack.app으로 실행할 때만 가능해요.",
        "Downloading the update from iCloud… try again in a moment.": "iCloud에서 업데이트를 내려받는 중이에요… 잠시 후 다시 시도하세요.",
        "Installing update…": "업데이트 설치 중…",
        "Update failed: %@": "업데이트 실패: %@",
        "The update package is incomplete.": "업데이트 파일이 불완전해요.",
        "This update isn't signed by the DayStack publisher, so it wasn't installed. If it was just published, it may still be syncing; try again in a minute.": "DayStack 배포자가 서명한 업데이트가 아니라서 설치하지 않았어요. 방금 배포된 경우 아직 동기화 중일 수 있으니 1분 뒤 다시 시도하세요.",
        "This update is not newer than the installed version.": "설치된 버전보다 새 버전이 아니에요.",
        // Reminders
        "Allow DayStack in System Settings → Privacy & Security → Reminders, then turn sync on again.": "시스템 설정 → 개인정보 보호 및 보안 → 미리 알림에서 DayStack을 허용한 뒤 동기화를 다시 켜주세요.",
        "Couldn't access Reminders: %@": "미리 알림에 접근하지 못했어요: %@",
        "Reminders sync failed: %@": "미리 알림 동기화 실패: %@",
        "No Reminders account found.": "미리 알림 계정을 찾지 못했어요.",
        // Settings
        "Calendar": "캘린더",
        "Heatmap color": "히트맵 색상",
        "Week starts on": "한 주의 시작",
        "Monday": "월요일",
        "Sunday": "일요일",
        "Language": "언어",
        "Auto": "자동",
        "General": "일반",
        "Open at login": "로그인 시 열기",
        "Sync with Reminders": "미리 알림과 동기화",
        "Two-way sync with a \"DayStack\" list in Apple Reminders, on your iPhone too.": "Apple 미리 알림의 \"DayStack\" 목록과 양방향으로 동기화해요. iPhone에서도 보여요.",
        "iPhone widget": "iPhone 위젯",
        "Ready": "준비됨",
        "Needs Scriptable": "Scriptable 필요",
        "On your iPhone: add a Scriptable widget, long-press it → Edit Widget → Script: DayStack.": "iPhone에서: Scriptable 위젯을 추가하고 길게 눌러 → 위젯 편집 → Script: DayStack을 선택하세요.",
        "Install the free Scriptable app on your iPhone (iCloud on), then come back here.": "iPhone에 무료 앱 Scriptable을 설치하고 (iCloud 켜기) 다시 여기로 오세요.",
        "Lets Claude add and edit your to-dos, e.g. \"add a plan: gym tomorrow 7pm\".": "Claude가 할 일을 추가하고 수정할 수 있어요. 예: \"내일 저녁 7시 헬스 일정 추가해줘\".",
        "Update to %@": "%@ 버전으로 업데이트",
        "Quit DayStack": "DayStack 종료",
        "Not installed": "설치 안 됨",
        "Connected": "연결됨",
        "Disconnect": "연결 해제",
        "Reconnect": "다시 연결",
        "DayStack moved since it was connected": "연결한 뒤 DayStack 위치가 바뀌었어요",
        "Connect": "연결",
        "Restart Claude Desktop to apply.": "적용하려면 Claude Desktop을 다시 시작하세요.",
        "Connected. Restart Claude Desktop to apply.": "연결됐어요. 적용하려면 Claude Desktop을 다시 시작하세요.",
        "Connected. Start a new Claude Code session to use it.": "연결됐어요. 새 Claude Code 세션에서 사용할 수 있어요.",
        "Couldn't update Claude: %@": "Claude 설정을 바꾸지 못했어요: %@",
        "Claude Code isn't installed.": "Claude Code가 설치되어 있지 않아요.",
        "Claude Desktop's config file isn't valid JSON, so it was left untouched.": "Claude Desktop 설정 파일이 올바른 JSON이 아니라서 건드리지 않았어요.",
        "Grey": "회색",
        "Green": "초록",
        "Blue": "파랑",
        "Purple": "보라",
        "Pink": "분홍",
        "Orange": "주황",
    ]
}

/// Localized text for an English key, with optional printf-style arguments (%@, %d).
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = L10n.isKorean ? (L10n.ko[key] ?? key) : key
    return args.isEmpty ? format : String(format: format, locale: L10n.locale, arguments: args)
}

extension Date {
    func fmt(_ style: Date.FormatStyle) -> String { formatted(style.locale(L10n.locale)) }

    var relativeText: String {
        var style = Date.RelativeFormatStyle(presentation: .named)
        style.locale = L10n.locale
        return formatted(style)
    }
}
