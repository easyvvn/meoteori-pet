// 머털이 데스크톱 펫
// 화면 아래를 돌아다니다가 Claude Code 상태(작업 중 · 확인 필요 · 준비됨)를 몸짓과 알림 카드로 보여준다.
// 상태는 Claude Code 훅이 ~/.meoteori/inbox/ 에 떨군 JSON 파일로 받는다.
// Codex 훅도 같은 형식이라 같이 받는다. Codex 훅은 파일 이름을 codex- 로 시작해서 구분한다.

import AppKit
import QuartzCore

// MARK: - 상태

enum PetMood: String, Codable {
    case idle, working, waiting, done, sleeping
}

struct SessionInfo: Codable {
    var id: String
    var title: String
    var project: String
    var mood: PetMood
    var updated: Date
    var detail: String? = nil   // 확인 필요일 때 무엇을
    var started = Date()        // 작업 시작
    var finished: Date? = nil   // 끝난 시각
    var changed = Date()        // 상태가 바뀐 시각
    var seen = true             // 끝난 걸 봤는지
    var desktopID: String? = nil    // Claude 앱 세션 번호 (local_…), 앱에서 연 세션만
    var desktopTitle: String? = nil // Claude 앱 사이드바 제목
    var agent: String? = nil        // "codex"면 Codex 세션, 없으면 Claude
    var name: String { desktopTitle ?? title }
}

// MARK: - Claude 앱 세션 찾기
// 앱은 세션마다 claude-code-sessions/…/local_<번호>.json 에 cliSessionId(훅의 session_id)를 같이 적는다.
// 그걸로 'claude://code/continue?session=local_…' 링크를 만들어 그 세션으로 바로 연다.

enum DesktopSessions {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")

    // 최근에 바뀐 파일부터 훑는다 (느릴 수 있어 백그라운드에서만 부른다)
    static func find(_ cli: String) -> (id: String, title: String)? {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var files: [(URL, Date)] = []
        for case let u as URL in e where u.lastPathComponent.hasPrefix("local_") && u.pathExtension == "json" {
            files.append((u, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        let needle = Data(cli.utf8)
        for (u, _) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let data = try? Data(contentsOf: u, options: .mappedIfSafe), data.range(of: needle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["cliSessionId"] as? String == cli, let id = obj["sessionId"] as? String, id.hasPrefix("local_") else { continue }
            return (id, (obj["title"] as? String) ?? "")
        }
        return nil
    }
}

// MARK: - 훅 이벤트 받기

final class Inbox {
    // Claude 훅은 ~/.meoteori/inbox 에 쓴다.
    // Codex 훅은 Codex 샌드박스 안에서 돌아서 홈 폴더에 못 쓰고, 샌드박스가 열어 두는 내 임시 폴더($TMPDIR)에 쓴다.
    let dirs: [URL]
    var onEvent: (([String: Any]) -> Void)?

    init() {
        dirs = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meoteori/inbox"),
                URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("meoteori-inbox")]
        for d in dirs { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
    }

    func poll() {
        let files = dirs.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        guard !files.isEmpty else { return }
        // 훅 파일 이름은 초 단위라 순서는 수정 시각(나노초)으로 정한다
        func mtime(_ u: URL) -> Date { (try? FileManager.default.attributesOfItem(atPath: u.path)[.modificationDate] as? Date) ?? .distantPast }
        let sorted = files.filter { $0.pathExtension == "json" }.sorted { mtime($0) < mtime($1) }
        for f in sorted {
            // 훅이 아직 쓰는 중일 수 있어 0.2초 지난 파일만 읽는다
            if let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
               let m = attrs[.modificationDate] as? Date, Date().timeIntervalSince(m) < 0.2 { continue }
            if let data = try? Data(contentsOf: f),
               var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if f.lastPathComponent.hasPrefix("codex-") { obj["_agent"] = "codex" }
                onEvent?(obj)
            }
            try? FileManager.default.removeItem(at: f)
        }
    }
}

// MARK: - 알림 카드

// 알림 색은 핑크 · 블루 · 블랙(딥)만. 확인 필요 = 핑크, 준비됨 = 블루(조끼 계열)
let okColor = NSColor(red: 0x3D/255.0, green: 0x74/255.0, blue: 0xC4/255.0, alpha: 1) // #3D74C4
let okTint = NSColor(red: 0xE3/255.0, green: 0xEE/255.0, blue: 0xFA/255.0, alpha: 1) // #E3EEFA
let workColor = NSColor(red: 0x1A/255.0, green: 0x1C/255.0, blue: 0x20/255.0, alpha: 1) // 블랙 = RDS gray/1000 #1A1C20 (자주색 딥 쓰지 말 것)
let brandPink = NSColor(red: 1, green: 0xAB/255.0, blue: 0xE5/255.0, alpha: 1) // #FFABE5 (외주 작업색, 최종 나오면 교체)
let pinkTint = NSColor(red: 1, green: 0.93, blue: 0.98, alpha: 1)
let warnColor = brandPink

final class CardView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subLabel = NSTextField(labelWithString: "")
    let badge = CALayer()
    let badgeIcon = CALayer()
    let spinner = CAShapeLayer()
    let openText = CATextLayer()
    var shownMood: PetMood?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = frame.height / 2
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        titleLabel.font = .systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = NSColor(white: 0.08, alpha: 1)
        titleLabel.lineBreakMode = .byTruncatingTail
        subLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subLabel.textColor = NSColor(white: 0.45, alpha: 1)
        subLabel.lineBreakMode = .byTruncatingTail
        let tx: CGFloat = 20, tw = frame.width - tx - 66
        titleLabel.frame = NSRect(x: tx, y: frame.height / 2 - 1, width: tw, height: 19)
        subLabel.frame = NSRect(x: tx, y: frame.height / 2 - 19, width: tw, height: 17)
        addSubview(titleLabel)
        addSubview(subLabel)

        layer?.addSublayer(badge)
        badgeIcon.contentsGravity = .resizeAspect
        badge.addSublayer(badgeIcon)
        spinner.fillColor = nil
        spinner.lineWidth = 2.5
        spinner.lineCap = .round
        spinner.strokeStart = 0
        spinner.strokeEnd = 0.7
        badge.addSublayer(spinner)
        openText.string = "열기"
        openText.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        openText.fontSize = 12
        openText.foregroundColor = NSColor.white.cgColor
        openText.alignmentMode = .center
        openText.contentsScale = 2
        badge.addSublayer(openText)
    }

    required init?(coder: NSCoder) { fatalError() }

    // 글자는 매번, 배지는 상태가 바뀔 때만 (돌던 스피너가 끊기지 않게)
    func show(title: String, sub: String, mood: PetMood) {
        titleLabel.stringValue = title
        subLabel.stringValue = sub
        guard mood != shownMood else { return }
        shownMood = mood
        func symbol(_ name: String, _ color: NSColor) -> CGImage? {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold).applying(.init(paletteColors: [color]))
            return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)?
                .cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spinner.removeAllAnimations()
        spinner.isHidden = true
        badgeIcon.isHidden = false
        openText.isHidden = true
        layer?.borderWidth = 0
        let bs: CGFloat = 30
        var bf = CGRect(x: frame.width - bs - 14, y: (frame.height - bs) / 2, width: bs, height: bs)
        switch mood {
        case .done:
            badge.backgroundColor = okTint.cgColor
            badgeIcon.contents = symbol("checkmark", okColor)
        case .waiting:
            // 확인 필요: 핑크 테두리 + '열기' 버튼
            layer?.borderWidth = 2
            layer?.borderColor = warnColor.cgColor
            bf = CGRect(x: frame.width - 46 - 12, y: (frame.height - 28) / 2, width: 46, height: 28)
            badge.backgroundColor = workColor.cgColor
            badgeIcon.isHidden = true
            openText.isHidden = false
        default:
            badge.backgroundColor = brandPink.cgColor
            badgeIcon.isHidden = true
            spinner.isHidden = false
            spinner.strokeColor = workColor.cgColor
        }
        badge.frame = bf
        badge.cornerRadius = bf.height / 2
        badgeIcon.frame = badge.bounds.insetBy(dx: 7, dy: 7)
        spinner.frame = badge.bounds
        spinner.path = CGPath(ellipseIn: badge.bounds.insetBy(dx: 6, dy: 6), transform: nil)
        openText.frame = CGRect(x: 0, y: (bf.height - 16) / 2, width: bf.width, height: 16)
        CATransaction.commit()
        if mood == .working {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -Double.pi * 2
            spin.duration = 0.9
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
        }
    }
}

// 마우스를 올리면 펼쳐지는 세션 목록 (급한 순서, 최대 4줄)
final class ListView: NSView {
    struct Row { let id: String; let color: NSColor; let title: String; let time: String }
    let rowH: CGFloat = 34, padV: CGFloat = 6
    var ids: [String] = []
    let hl = CALayer()            // 마우스가 올라간 줄
    var hoverRow = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 18
        hl.cornerRadius = 12
        hl.backgroundColor = pinkTint.cgColor
        layer?.addSublayer(hl)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ rows: [Row]) {
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.filter { $0.name == "deco" }.forEach { $0.removeFromSuperlayer() }
        ids = rows.map { $0.id }
        let w = frame.width, h = padV * 2 + rowH * CGFloat(rows.count)
        setFrameSize(NSSize(width: w, height: h))
        for (i, r) in rows.enumerated() {
            let y = h - padV - rowH * CGFloat(i + 1)
            let dot = CALayer()
            dot.name = "deco"
            dot.frame = CGRect(x: 18, y: y + rowH / 2 - 4, width: 8, height: 8)
            dot.cornerRadius = 4
            dot.backgroundColor = r.color.cgColor
            layer?.addSublayer(dot)
            let t = NSTextField(labelWithString: r.title)
            t.font = .systemFont(ofSize: 13, weight: .semibold)
            t.textColor = NSColor(white: 0.08, alpha: 1)
            t.lineBreakMode = .byTruncatingTail
            t.frame = NSRect(x: 34, y: y + 8, width: w - 34 - 70, height: 18)
            addSubview(t)
            let s = NSTextField(labelWithString: r.time)
            s.font = .systemFont(ofSize: 11.5)
            s.textColor = NSColor(white: 0.45, alpha: 1)
            s.alignment = .right
            s.frame = NSRect(x: w - 78, y: y + 9, width: 64, height: 16)
            addSubview(s)
        }
        hoverRow = min(hoverRow, max(0, rows.count - 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hl.frame = CGRect(x: 6, y: h - padV - rowH * CGFloat(hoverRow + 1), width: w - 12, height: rowH)
        CATransaction.commit()
    }

    // 마우스 아래 줄을 밝게 (누를 수 있다는 표시)
    func highlight(at p: NSPoint) {
        let i = Int((frame.maxY - padV - p.y) / rowH)
        guard ids.indices.contains(i) else { return }
        hoverRow = i
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        hl.frame = CGRect(x: 6, y: frame.height - padV - rowH * CGFloat(i + 1), width: frame.width - 12, height: rowH)
        CATransaction.commit()
    }

    // 창 좌표 → 몇 번째 줄
    func row(at p: NSPoint) -> String? {
        let i = Int((frame.maxY - padV - p.y) / rowH)
        return ids.indices.contains(i) ? ids[i] : nil
    }
}

// MARK: - 펫 창

final class PetController: NSObject {
    let panel: NSPanel
    let root: NSView
    let petLayer = CALayer()      // 몸 (이동·기울기)
    let bodyLayer = CALayer()     // 그림 (찌그러짐·뒤집기)
    let shadowLayer = CALayer()
    let fxLayer = CALayer()       // 말풍선 효과
    let chevron = CATextLayer()
    let card: CardView
    let listView: ListView
    let stackBand = CALayer()     // 카드 뒤 겹친 띠 (세션 더 있음)
    let pinWarn = CALayer()       // 접혔을 때 머리 위 점
    let pinOk = CALayer()

    let winW: CGFloat = 340, winH: CGFloat = 320 // 하트 · 반짝이가 잘리지 않게 넉넉히
    // 창 아래 여백: 카드 그림자가 창 끝에서 잘리지 않게. 바닥(posY)보다 창을 이만큼 내려 둔다
    static let floorPad: CGFloat = 16
    let cardW: CGFloat = 234
    var petW: CGFloat = 112
    var petH: CGFloat = 112
    var petSize: CGFloat { petH }
    var cardShown = false
    var cardCollapsed = false

    var mood: PetMood = .idle
    var moodStart = Date()
    var sessions: [String: SessionInfo] = [:]
    var lastActivity = Date()

    // 산책
    var walkEnabled = true
    var posX: CGFloat = 0
    var posY: CGFloat = 0 // 창 아래 끝. 끌어다 놓은 높이에서 그 줄을 따라 걷는다
    var targetX: CGFloat?
    var facing: CGFloat = 1
    var restUntil = Date().addingTimeInterval(4)

    var dragOffset: NSPoint?
    var dragMoved = false
    var lastTick = CACurrentMediaTime()
    var timer: Timer?
    let inbox = Inbox()

    override init() {
        // 켤 때는 메뉴 막대가 있는 모니터 오른쪽 아래
        let screen = (NSScreen.screens.first ?? NSScreen.main!).visibleFrame
        panel = NSPanel(contentRect: NSRect(x: screen.maxX - winW - 40, y: screen.minY, width: winW, height: winH),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        root = NSView(frame: NSRect(x: 0, y: 0, width: winW, height: winH))
        root.wantsLayer = true
        panel.contentView = root

        card = CardView(frame: NSRect(x: (winW - cardW) / 2, y: 10 + PetController.floorPad, width: cardW, height: 58))
        listView = ListView(frame: NSRect(x: (winW - cardW) / 2, y: 8 + PetController.floorPad, width: cardW, height: 60))
        super.init()

        posX = panel.frame.minX
        posY = panel.frame.minY
        // 마지막에 놓아 둔 자리 (그 화면이 아직 있으면)
        if let s = UserDefaults.standard.array(forKey: "petPos") as? [Double], s.count == 2,
           NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: s[0] + Double(winW) / 2, y: s[1])) }) {
            posX = s[0]; posY = s[1]
        }

        // 그림자
        // 바닥 그림자: 흐린 타원
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.18
        shadowLayer.shadowRadius = 5
        shadowLayer.shadowOffset = .zero
        root.layer!.addSublayer(shadowLayer)

        // 몸
        poses = PetController.loadPoses()
        // 컷 묶음: pose_<이름>1~N 이 있으면 그 동작은 컷을 넘기며 움직인다. 첫 컷이 대표 그림
        for name in Set(poses.keys.compactMap { k -> String? in k.last?.isNumber == true ? String(k.dropLast()) : nil }) {
            let fr = (1...8).compactMap { poses["\(name)\($0)"] }
            if fr.count > 1 { anims[name] = fr; poses[name] = fr[0] }
        }
        walkFrames = anims["walk"] ?? []
        petLayer.bounds = CGRect(x: 0, y: 0, width: petW, height: petH)
        petLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.frame = petLayer.bounds
        bodyLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        bodyLayer.position = CGPoint(x: petW / 2, y: 0)
        bodyLayer.contentsGravity = .resizeAspect
        bodyLayer.minificationFilter = .trilinear
        bodyLayer.contentsScale = 2
        setPose(poses["lie"] != nil ? "lie" : "main", animated: false)
        petLayer.addSublayer(bodyLayer)
        root.layer!.addSublayer(petLayer)

        fxLayer.frame = root.bounds
        fxLayer.zPosition = 10 // 하트 · 반짝이는 카드보다 위
        root.layer!.addSublayer(fxLayer)

        chevron.string = "︿"
        chevron.fontSize = 18
        chevron.font = NSFont.systemFont(ofSize: 18, weight: .heavy)
        chevron.foregroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor
        chevron.alignmentMode = .center
        chevron.contentsScale = 2
        chevron.bounds = CGRect(x: 0, y: 0, width: 24, height: 22)
        chevron.opacity = 0
        // 접기 꺾쇠는 머털이 옆에 떠서 헷갈려 안 붙임 (10/20)

        stackBand.frame = CGRect(x: (winW - cardW) / 2 + 18, y: 4, width: cardW - 36, height: 20)
        stackBand.cornerRadius = 10
        stackBand.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        stackBand.shadowOpacity = 0.12
        stackBand.shadowRadius = 4
        stackBand.shadowOffset = CGSize(width: 0, height: -1)
        stackBand.opacity = 0
        root.layer!.insertSublayer(stackBand, at: 0)

        card.isHidden = true
        root.addSubview(card)
        listView.wantsLayer = true
        listView.layer?.opacity = 0
        root.addSubview(listView)

        for (pin, color, sym, ink) in [(pinWarn, warnColor, "exclamationmark", workColor), (pinOk, okColor, "checkmark", NSColor.white)] {
            pin.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
            pin.cornerRadius = 11
            pin.backgroundColor = color.cgColor
            pin.borderColor = NSColor.white.cgColor
            pin.borderWidth = 2.5
            let icon = symbolLayer(sym, ink, size: 9)
            icon.position = CGPoint(x: 11, y: 11)
            pin.addSublayer(icon)
            pin.isHidden = true
            root.layer!.addSublayer(pin)
        }

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            // Claude 앱을 열면 끝난 건 본 걸로
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if ["com.anthropic.claudefordesktop", "com.anthropic.claude"].contains(app?.bundleIdentifier ?? "") {
                self?.markDoneSeen()
            }
        }

        inbox.onEvent = { [weak self] in self?.handle(event: $0) }
        loadSessions()

        timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)

        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.mouse(e); return e
        }
        panel.orderFrontRegardless()

        // 데스크톱(Space) 전환 · 모니터 꽂고 빼기 · 잠자기 뒤에도 다시 앞으로
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.keepVisible() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.keepVisible() }
    }

    // 머털이는 사라지면 안 된다: 메뉴에서 직접 숨긴 게 아니면 창을 다시 띄우고, 그림이 비었으면 다시 넣는다
    var hiddenByUser = false
    func keepVisible() {
        guard !hiddenByUser else { return }
        if !panel.isVisible || !panel.isOnActiveSpace { panel.orderFrontRegardless() }
        if bodyLayer.contents == nil, let img = poses[pose] ?? poses["lie"] { bodyLayer.contents = img }
        // 꺼진 모니터에 남아 있으면 메뉴 막대 모니터로
        let center = NSPoint(x: posX + winW / 2, y: panel.frame.midY)
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -1, dy: -400).contains(center) }), let main = NSScreen.screens.first {
            posX = main.visibleFrame.maxX - winW - 40
            posY = main.visibleFrame.minY
        }
    }

    // Resources/pose_<이름>.png 를 모두 읽는다. 없으면 meoteori.png 하나로.
    static func loadPoses() -> [String: CGImage] {
        var out: [String: CGImage] = [:]
        let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: nil) ?? []
        for u in urls {
            let name = u.deletingPathExtension().lastPathComponent
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            // 컷(walk1~4, work1~4 …)은 같은 캔버스로 잘려 있어 따로 자르지 않는다 (컷마다 크기가 달라지면 떨림)
            if name.hasPrefix("pose_"), name.last?.isNumber == true { out[String(name.dropFirst(5))] = pinkRim(img) }
            else if name.hasPrefix("pose_") { out[String(name.dropFirst(5))] = pinkRim(trimTransparent(img)) }
            else if name == "meoteori" { out["main"] = pinkRim(trimTransparent(img)) }
        }
        return out
    }

    var poses: [String: CGImage] = [:]
    var pose = ""
    var poseFlip = false
    var walkFrames: [CGImage] = []
    var anims: [String: [CGImage]] = [:]

    func showFrame(_ f: CGImage) {
        if (bodyLayer.contents as AnyObject?) !== f {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            bodyLayer.contents = f
            CATransaction.commit()
        }
    }

    // 걷기 말고 다른 동작도 한 장에 멈춰 있지 않게 컷을 넘긴다
    // 계속 움직이는 것(타자 · 긁기 · 버둥 · 폴짝 · 킁킁 · 숨)과 쉬다가 가끔(깜빡 · 갸웃)으로 나눈다
    var idleBeat: (until: Double, frame: Int) = (0, 0)
    var nextIdleBeat: Double = 0
    func animTick(_ now: Double) {
        guard pose != "walk", let fr = anims[pose], fr.count >= 4 else { return }
        var i = 0
        switch pose {
        case "work": i = Int(now * 6) % 4                 // 왼발 탁 · 들기 · 오른발 탁 · 들기
        case "scratch": i = Int(now * 10) % 4
        case "belly", "happy": i = Int(now * 4) % 4
        case "sniff": i = Int(now * 2.5) % 4
        case "wait": i = [0, 1, 0, 2, 0, 3][Int(now / 0.7) % 6]
        case "sleep": i = [0, 1, 0, 3, 0, 1, 0, 2][Int(now / 1.4) % 8]
        case "stretch", "yawn":
            // 한 번만: 시작 → 중간 → 끝(머묾) → 돌아옴
            let p = action.map { min(1, Date().timeIntervalSince($0.start) / $0.dur) } ?? 0.5
            i = p < 0.15 ? 0 : p < 0.3 ? 1 : p < 0.8 ? 2 : 3
        case "ball":
            // 가끔 공을 굴렸다 당겨 온다
            if now > nextIdleBeat { nextIdleBeat = now + Double.random(in: 3...6); idleBeat = (now + 1.6, 1) }
            i = now < idleBeat.until ? 1 + min(2, Int((1.6 - (idleBeat.until - now)) / 0.55)) : 0
        default:
            // 앉기 · 엎드리기 · 올려다보기: 대부분 첫 컷, 2~5초마다 한 컷 잠깐
            if now > nextIdleBeat {
                nextIdleBeat = now + Double.random(in: 2...5)
                let f = Int.random(in: 1..<fr.count)
                let blink = (pose == "look" && f == 3) || (pose != "look" && f == 1)
                idleBeat = (now + (blink ? 0.18 : 1.2), f)
            }
            i = now < idleBeat.until ? idleBeat.frame : 0
        }
        showFrame(fr[i % fr.count])
    }

    // 걸을 때: 다리 번갈아 4컷을 초당 8컷으로 넘긴다. 컷이 없으면 예전처럼 한 장 + 통통
    func walkStep(_ now: Double) -> CGFloat {
        setPose("walk")
        guard !walkFrames.isEmpty else { return abs(CGFloat(sin(now * 4.5))) * 1.5 }
        showFrame(walkFrames[Int(now * 8) % walkFrames.count])
        return 0
    }

    // 포즈 바꾸기: 높이 100 기준, 폭은 150 안으로. 살짝 겹쳐 바뀐다.
    func setPose(_ name: String, animated: Bool = true) {
        let key = poses[name] != nil ? name : (poses["lie"] != nil ? "lie" : "main")
        guard key != pose, let img = poses[key] else { return }
        pose = key
        let aspect = CGFloat(img.width) / CGFloat(img.height)
        petH = 100
        petW = petH * aspect
        if petW > 150 { petW = 150; petH = petW / aspect }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        petLayer.bounds = CGRect(x: 0, y: 0, width: petW, height: petH)
        bodyLayer.bounds = petLayer.bounds
        bodyLayer.position = CGPoint(x: petW / 2, y: 0)
        CATransaction.commit()
        bodyLayer.contents = img
        if animated {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.22
            bodyLayer.add(fade, forKey: "pose")
        }
    }

    // 흰 테두리 바깥에 연회색 실선 (흰 창 위에서도 스티커 모양이 보이게). 화면에서 약 1pt
    // 그림에 붙어 온 흰 스티커 테두리를 흰색으로 (안쪽 2.1% 칠하고 바깥으로 0.4% 더 넓힘, 10/20 두꺼워서 1.2→0.4, 10/21 핑크→흰색)
    static func pinkRim(_ img: CGImage, frac: Double = 0.021) -> CGImage {
      let w = img.width, h = img.height
      guard let k = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
      k.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
      guard let p = k.data?.bindMemory(to: UInt8.self, capacity: w*h*4) else { return img }
      // 두 번 훑는 거리 변환 (3-4 chamfer)
      let big = Int32.max / 2
      var d = [Int32](repeating: big, count: w*h)
      for i in 0..<(w*h) where p[i*4+3] < 128 { d[i] = 0 }
      for y in 0..<h { for x in 0..<w { let i = y*w+x; if d[i] == 0 { continue }
        var m = d[i]
        if x > 0 { m = min(m, d[i-1] + 3) } else { m = min(m, 3) }
        if y > 0 { m = min(m, d[i-w] + 3); if x > 0 { m = min(m, d[i-w-1] + 4) }; if x < w-1 { m = min(m, d[i-w+1] + 4) } } else { m = min(m, 3) }
        d[i] = m } }
      for y in stride(from: h-1, through: 0, by: -1) { for x in stride(from: w-1, through: 0, by: -1) { let i = y*w+x; if d[i] == 0 { continue }
        var m = d[i]
        if x < w-1 { m = min(m, d[i+1] + 3) } else { m = min(m, 3) }
        if y < h-1 { m = min(m, d[i+w] + 3); if x < w-1 { m = min(m, d[i+w+1] + 4) }; if x > 0 { m = min(m, d[i+w-1] + 4) } } else { m = min(m, 3) }
        d[i] = m } }
      let R = Double(min(w, h)) * frac, soft = 3.0
      let pk: (Double, Double, Double) = (255, 255, 255) // 흰색
      for i in 0..<(w*h) where d[i] > 0 {
        let dist = Double(d[i]) / 3
        let t = min(1, max(0, (dist - R) / soft)) // 0 = 핑크, 1 = 원래 그림
        if t >= 1 { continue }
        let a = Double(p[i*4+3]) / 255
        p[i*4]   = UInt8(min(255, (pk.0 * a) * (1-t) + Double(p[i*4]) * t))
        p[i*4+1] = UInt8(min(255, (pk.1 * a) * (1-t) + Double(p[i*4+1]) * t))
        p[i*4+2] = UInt8(min(255, (pk.2 * a) * (1-t) + Double(p[i*4+2]) * t))
      }
      guard let inner = k.makeImage() else { return img }
        // 바깥으로 핑크 띠를 더 붙여 두껍게
        let r = CGFloat(min(w, h)) * 0.004, pad = Int(ceil(r)) + 2
        guard let o = CGContext(data: nil, width: w + pad * 2, height: h + pad * 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let sk = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return inner }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        sk.draw(inner, in: full); sk.setBlendMode(.sourceIn)
        sk.setFillColor(CGColor(srgbRed: pk.0 / 255, green: pk.1 / 255, blue: pk.2 / 255, alpha: 1)); sk.fill(full)
        guard let sil = sk.makeImage() else { return inner }
        for a in 0..<32 {
            let t = Double(a) / 32 * .pi * 2
            o.draw(sil, in: full.offsetBy(dx: CGFloat(pad) + CGFloat(cos(t)) * r, dy: CGFloat(pad) + CGFloat(sin(t)) * r))
        }
        o.draw(inner, in: full.offsetBy(dx: CGFloat(pad), dy: CGFloat(pad)))
        return o.makeImage() ?? inner
    }

    static func outlined(_ img: CGImage) -> CGImage {
        let r = max(1.5, CGFloat(img.height) / 100 * 1.0)
        let pad = Int(ceil(r)) + 2
        let w = img.width + pad * 2, h = img.height + pad * 2
        func ctx(_ w: Int, _ h: Int) -> CGContext? {
            CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let sk = ctx(img.width, img.height), let k = ctx(w, h) else { return img }
        let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        sk.draw(img, in: full)
        sk.setBlendMode(.sourceIn)
        sk.setFillColor(NSColor(white: 0.80, alpha: 1).cgColor)
        sk.fill(full)
        guard let sil = sk.makeImage() else { return img }
        for i in 0..<24 {
            let t = Double(i) / 24 * .pi * 2
            k.draw(sil, in: full.offsetBy(dx: CGFloat(pad) + CGFloat(cos(t)) * r, dy: CGFloat(pad) + CGFloat(sin(t)) * r))
        }
        k.draw(img, in: full.offsetBy(dx: CGFloat(pad), dy: CGFloat(pad)))
        return k.makeImage() ?? img
    }

    // 투명 여백을 잘라 그림이 칸을 꽉 채우게
    static func trimTransparent(_ img: CGImage) -> CGImage {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let p = ctx.data?.bindMemory(to: UInt8.self, capacity: w * h * 4) else { return img }
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h { for x in 0..<w where p[(y * w + x) * 4 + 3] > 16 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX > minX, maxY > minY else { return img }
        // 이 컨텍스트의 메모리는 위쪽 행부터
        return img.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) ?? img
    }

    // MARK: 이벤트

    func handle(event e: [String: Any]) {
        let name = e["hook_event_name"] as? String ?? ""
        let sid = e["session_id"] as? String ?? "default"
        let cwd = e["cwd"] as? String ?? ""
        let project = (cwd as NSString).lastPathComponent
        let agent = e["_agent"] as? String
        var s = sessions[sid] ?? SessionInfo(id: sid, title: project.isEmpty ? (agent == "codex" ? "Codex 작업" : "Claude 작업") : project,
                                             project: project, mood: .idle, updated: Date())
        if !project.isEmpty { s.project = project }
        if agent != nil { s.agent = agent }
        let old = s.mood

        switch name {
        case "UserPromptSubmit":
            let prompt = (e["prompt"] as? String ?? "")
                .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            if !prompt.isEmpty { s.title = String(prompt.prefix(22)) + (prompt.count > 22 ? "…" : "") }
            s.mood = .working
            s.started = Date(); s.finished = nil; s.detail = nil; s.seen = true
        case "PreToolUse" where ["AskUserQuestion", "ExitPlanMode"].contains(e["tool_name"] as? String ?? ""):
            // 질문 · 계획 확인은 도구처럼 오지만 실제로는 내 답을 기다리는 중
            s.mood = .waiting
            s.detail = (e["tool_name"] as? String) == "ExitPlanMode" ? "계획 확인 필요" : "질문에 답해 주세요"
        case "PreToolUse", "PostToolUse", "PostToolUseFailure":
            s.updated = Date()
            guard s.mood != .working else { sessions[sid] = s; return }
            if s.mood != .waiting { s.started = Date() }
            s.mood = .working; s.detail = nil; s.finished = nil; s.seen = true
        case "PermissionRequest":
            s.mood = .waiting
            s.detail = PetController.askText(e["tool_name"] as? String)
        case "Notification":
            let msg = e["message"] as? String ?? ""
            if msg.localizedCaseInsensitiveContains("waiting for your input") {
                // 끝난 뒤 오는 재알림은 무시
                if s.mood == .done || s.mood == .idle { return }
                s.detail = "답을 기다려요"
            } else if let r = msg.range(of: "permission to use ") {
                if s.mood == .waiting && s.detail != nil { return }
                s.detail = PetController.askText(String(msg[r.upperBound...]))
            } else {
                s.detail = msg.isEmpty ? "확인이 필요해요" : msg
            }
            s.mood = .waiting
        case "Stop":
            s.mood = .done; s.finished = Date(); s.seen = false; s.detail = nil
        case "Interrupt":
            // Codex에서 사용자가 멈춤: 끝난 게 아니라 그냥 쉬는 상태로
            s.mood = .idle; s.detail = nil
        case "SessionEnd":
            sessions[sid] = nil
            refreshAll(); saveSessions()
            return
        case "MeoteoriTest":
            s.title = e["title"] as? String ?? "테스트"
            s.mood = PetMood(rawValue: e["mood"] as? String ?? "") ?? .done
            s.started = Date().addingTimeInterval(-(e["ago"] as? Double ?? 0))
            if s.mood == .waiting { s.detail = PetController.askText("Bash") }
            if s.mood == .done { s.finished = Date().addingTimeInterval(-(e["ago"] as? Double ?? 0)); s.seen = false }
        default:
            return
        }
        if s.mood != old { s.changed = Date() }
        s.updated = Date()
        sessions[sid] = s
        lastActivity = Date()
        cardCollapsed = false
        refreshAll(); saveSessions()
    }

    // 세션 상태를 파일에 남겨 앱을 다시 켜도 이어지게 (~/.meoteori/sessions.json)
    static let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".meoteori/sessions.json")
    var savedState: Data?
    func saveSessions() {
        guard let d = try? JSONEncoder().encode(sessions), d != savedState else { return }
        savedState = d
        try? d.write(to: PetController.stateURL, options: .atomic)
    }
    func loadSessions() {
        guard let d = try? Data(contentsOf: PetController.stateURL),
              let all = try? JSONDecoder().decode([String: SessionInfo].self, from: d) else { return }
        // 30분 넘게 소식 없는 건 버림
        sessions = all.filter { Date().timeIntervalSince($0.value.updated) < 1800 }
    }

    // 권한 요청을 쉬운 말로
    static func askText(_ tool: String?) -> String {
        guard var t = tool?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return "확인이 필요해요" }
        if t.hasPrefix("mcp__") { t = t.components(separatedBy: "__").last ?? t }
        let names = ["Bash": "터미널 명령", "Edit": "파일 수정", "MultiEdit": "파일 수정", "Write": "파일 쓰기",
                     "NotebookEdit": "노트북 수정", "WebFetch": "웹 열기", "WebSearch": "웹 검색", "Read": "파일 읽기",
                     // Codex 도구 이름
                     "shell": "터미널 명령", "local_shell": "터미널 명령", "exec_command": "터미널 명령", "apply_patch": "파일 수정"]
        return "\(names[t] ?? t) 허락 필요"
    }

    // 끝난 지 90초 넘은 '준비됨'은 카드 대신 점으로만
    func isStale(_ s: SessionInfo) -> Bool {
        s.mood == .done && Date().timeIntervalSince(s.finished ?? .distantPast) > 90
    }

    // 보여 줄 세션: 확인 필요 → 막 끝남 → 작업 중 → 안 본 준비됨
    func visibleSessions() -> [SessionInfo] {
        let list = sessions.values.filter {
            switch $0.mood {
            case .waiting: return true
            case .working: return Date().timeIntervalSince($0.updated) < 1800 // 30분 소식 없으면 멈춘 걸로
            case .done: return !$0.seen
            default: return false
            }
        }
        func rank(_ s: SessionInfo) -> Int {
            switch s.mood { case .waiting: return 0; case .done: return isStale(s) ? 3 : 1; default: return 2 }
        }
        return list.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.changed > $1.changed }
    }

    func timeText(_ s: SessionInfo, short: Bool = false) -> String {
        func ago(_ d: Date?) -> Int { Int(Date().timeIntervalSince(d ?? Date()) / 60) }
        switch s.mood {
        case .working:
            let m = ago(s.started); return m < 1 ? "방금 시작" : "\(m)분째"
        case .waiting:
            let m = ago(s.changed); return m < 1 ? "방금" : (short ? "\(m)분째" : "\(m)분째 기다려요")
        case .done:
            let m = ago(s.finished)
            return m < 1 ? "방금" : m < 60 ? "\(m)분 전" : "\(m / 60)시간 전"
        default: return ""
        }
    }

    // 세션 상태 → 몸짓 · 카드 · 목록 · 점
    func refreshAll() {
        let vis = visibleSessions()
        var want: PetMood = .idle
        if let top = vis.first, !isStale(top) { want = top.mood }
        if want != mood && !(mood == .sleeping && want == .idle) { setMood(want) }

        let showCard = !cardCollapsed && vis.first.map { !isStale($0) } == true
        if showCard, let top = vis.first {
            topID = top.id
            var sub: String
            switch top.mood {
            case .waiting: sub = "\(top.name) · \(timeText(top))"
            case .done: sub = "준비됨 · \(timeText(top))"
            default: sub = "작업 중 · \(timeText(top))"
            }
            // 세션이 여럿이면 프로젝트 대신 개수 (잘려도 개수는 보이게)
            if vis.count > 1 { sub += " · 외 \(vis.count - 1)개" }
            else if top.mood != .waiting && !top.project.isEmpty { sub += " · \(top.project)" }
            card.show(title: top.mood == .waiting ? (top.detail ?? "확인이 필요해요") : top.name, sub: sub, mood: top.mood)
        }
        setCard(visible: showCard)
        visibleCount = vis.count
        if hoverList {
            listView.set(vis.prefix(4).map { s in
                ListView.Row(id: s.id, color: s.mood == .waiting ? warnColor : s.mood == .done ? okColor : workColor,
                             title: s.mood == .waiting ? (s.detail ?? s.name) : s.name, time: timeText(s, short: true))
            })
        }
        stackBand.opacity = 0 // 겹친 띠는 '외 N개'와 겹쳐서 안 씀
        // 접혀 있을 때 안 본 것만 머리 위 점으로
        pinWarn.isHidden = cardShown || hoverList || !vis.contains { $0.mood == .waiting }
        pinOk.isHidden = cardShown || hoverList || !vis.contains { $0.mood == .done }
    }
    var topID: String?
    var visibleCount = 0

    // 그 세션으로 바로. Claude 앱 세션이 아니면 (터미널 · Orca) 앱만 앞으로
    func openSession(_ id: String?) {
        guard let id else { openClaude(); return }
        if sessions[id]?.mood == .done { sessions[id]?.seen = true }
        refreshAll()
        if sessions[id]?.agent == "codex" { openApp(["com.openai.codex"]); return }
        if let d = sessions[id]?.desktopID { openDesktop(d); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = DesktopSessions.find(id)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let r { self.sessions[id]?.desktopID = r.id; self.openDesktop(r.id) } else { self.openClaude() }
            }
        }
    }

    func openDesktop(_ local: String) {
        guard let url = URL(string: "claude://code/continue?session=\(local)") else { openClaude(); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(url, configuration: cfg)
    }

    // 보이는 세션의 Claude 앱 제목 · 번호를 30초마다 채운다 (제목은 앱이 나중에 바꾸기도 해서)
    func resolveDesktop() {
        let ids = visibleSessions().filter { $0.agent == nil }.map { $0.id }.filter { lookupAt[$0].map { Date().timeIntervalSince($0) > 30 } ?? true }
        guard !ids.isEmpty, !lookingUp else { return }
        lookingUp = true
        ids.forEach { lookupAt[$0] = Date() }
        DispatchQueue.global(qos: .utility).async {
            let found = ids.map { ($0, DesktopSessions.find($0)) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lookingUp = false
                for (id, r) in found {
                    guard let r else { continue }
                    self.sessions[id]?.desktopID = r.id
                    if !r.title.isEmpty { self.sessions[id]?.desktopTitle = r.title }
                }
                self.refreshAll()
            }
        }
    }
    var lookupAt: [String: Date] = [:]
    var lookingUp = false

    func markDoneSeen() {
        for (k, v) in sessions where v.mood == .done { sessions[k]?.seen = true }
        refreshAll(); saveSessions()
    }

    func setCard(visible: Bool) {
        guard visible != cardShown else { return }
        cardShown = visible
        card.isHidden = false
        card.wantsLayer = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in if self?.cardShown == false { self?.card.isHidden = true } }
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = visible ? 0.9 : 1
        a.toValue = visible ? 1 : 0.9
        a.damping = 22
        a.initialVelocity = 4
        a.duration = visible ? a.settlingDuration : 0.18
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = visible ? 0 : 1
        f.toValue = visible ? 1 : 0
        f.duration = 0.18
        card.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        card.layer?.position = CGPoint(x: card.frame.midX, y: card.frame.midY)
        card.layer?.opacity = visible ? 1 : 0
        card.layer?.add(a, forKey: "pop")
        card.layer?.add(f, forKey: "fade")
        CATransaction.commit()
        chevron.opacity = visible ? 1 : 0
    }

    // 목록 펼치기 · 접기
    func setHover(_ on: Bool) {
        guard on != hoverList else { return }
        hoverList = on
        refreshAll()
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        listView.layer?.opacity = on ? 1 : 0
        card.layer?.opacity = on ? 0 : (cardShown ? 1 : 0)
        chevron.opacity = on ? 0 : (cardShown ? 1 : 0)
        CATransaction.commit()
        listView.isHidden = false
    }
    var hoverList = false
    var hoverLeaveAt: Double?

    func setMood(_ m: PetMood) {
        guard m != mood else { return } // 같은 상태가 또 와도 다시 튀지 않게
        moodStart = Date()
        mood = m
        targetX = nil
        action = nil
        restUntil = Date().addingTimeInterval(restSpan())
        clearFx()
        switch m {
        case .working: setPose("work")
        case .waiting: setPose("wait")
        case .done: setPose("happy")
        case .sleeping: setPose("sleep")
        case .idle: setPose(restPick())
        }
        switch m {
        case .done:
            burst(symbol: "sparkle", color: brandPink, count: 3)
            bubble(symbol: "heart.fill", color: brandPink)
        case .waiting:
            bubble(symbol: "exclamationmark", color: workColor, keep: true)
        case .working:
            bubble(symbol: "ellipsis", color: workColor, keep: true)
        case .sleeping:
            bubble(symbol: "zzz", color: NSColor(white: 0.45, alpha: 1), keep: true)
        case .idle: break
        }
    }

    // MARK: 효과

    func clearFx() { fxLayer.sublayers?.forEach { $0.removeFromSuperlayer() } }
    func clearBubbles() { fxLayer.sublayers?.filter { $0.name == "bubble" || $0.name == "bubbleT" }.forEach { $0.removeFromSuperlayer() } }
    var bubblePos = CGPoint(x: 240, y: 180)

    func symbolLayer(_ name: String, _ color: NSColor, size: CGFloat) -> CALayer {
        let l = CALayer()
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .heavy).applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        l.contents = img?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        l.bounds = CGRect(x: 0, y: 0, width: size * 1.6, height: size * 1.6)
        l.contentsGravity = .resizeAspect
        l.contentsScale = 2
        return l
    }

    // 머리 위 말풍선 (흰 동그라미 + 기호)
    func bubble(symbol: String, color: NSColor, keep: Bool = false) {
        let b = CALayer()
        b.name = keep ? "bubble" : "bubbleT"
        b.position = bubblePos
        // 잠깐 뜨는 하트는 떠 있는 말풍선을 잠시 가리고 그 자리에
        let held = fxLayer.sublayers?.filter { $0.name == "bubble" } ?? []
        if keep { clearBubbles() } else {
            fxLayer.sublayers?.filter { $0.name == "bubbleT" }.forEach { $0.removeFromSuperlayer() }
            held.forEach { $0.opacity = 0 }
        }
        b.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        b.cornerRadius = 17
        b.backgroundColor = NSColor.white.cgColor
        // 테두리 없음 (10/21 핑크 선 뺌, 흰 바탕 + 그림자만)
        b.shadowOpacity = 0.15
        b.shadowRadius = 5
        b.shadowOffset = CGSize(width: 0, height: -1)
        let icon = symbolLayer(symbol, color, size: 14)
        icon.position = CGPoint(x: 17, y: 17)
        b.addSublayer(icon)
        fxLayer.addSublayer(b)

        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.2; pop.toValue = 1; pop.damping = 10; pop.duration = pop.settlingDuration
        b.add(pop, forKey: "pop")
        if keep {
            let fl = CABasicAnimation(keyPath: "transform.translation.y")
            fl.fromValue = 0; fl.toValue = 2; fl.duration = 1.4
            fl.autoreverses = true; fl.repeatCount = .infinity
            fl.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fl.beginTime = CACurrentMediaTime() + 0.4
            icon.add(fl, forKey: "float")
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak b] in
                guard let b else { return }
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    b.removeFromSuperlayer()
                    // 하트가 사라지면 가려 둔 말풍선을 다시
                    if self?.fxLayer.sublayers?.contains(where: { $0.name == "bubbleT" }) != true {
                        self?.fxLayer.sublayers?.filter { $0.name == "bubble" }.forEach { $0.opacity = 1 }
                    }
                }
                b.opacity = 0
                CATransaction.commit()
            }
        }
    }

    // 반짝이 터짐
    func burst(symbol: String, color: NSColor, count: Int) {
        let c = CGPoint(x: winW / 2 + walkOff, y: petBaseY + petSize * 0.6)
        for i in 0..<count {
            let s = symbolLayer(symbol, color, size: CGFloat.random(in: 9...14))
            s.position = c
            s.opacity = 0
            fxLayer.addSublayer(s)
            let ang = Double(i) / Double(count) * .pi * 2 + Double.random(in: -0.3...0.3)
            let r = CGFloat.random(in: 58...78)
            let to = CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r * 0.8 + 10)
            let mv = CABasicAnimation(keyPath: "position")
            mv.fromValue = c; mv.toValue = to
            mv.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0, 1, 1, 0]; op.keyTimes = [0, 0.1, 0.6, 1]
            let sc = CAKeyframeAnimation(keyPath: "transform.scale")
            sc.values = [0.3, 1.2, 0.8]; sc.keyTimes = [0, 0.3, 1]
            let g = CAAnimationGroup()
            g.animations = [mv, op, sc]
            g.duration = 1.1
            g.beginTime = CACurrentMediaTime() + 0.18
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            s.add(g, forKey: "burst")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { s.removeFromSuperlayer() }
        }
    }

    var petBaseY: CGFloat { hoverList ? listView.frame.maxY + 4 : (cardShown ? 66 : 6) + PetController.floorPad }
    var currentBaseY: CGFloat = 6 + PetController.floorPad

    // MARK: 매 프레임

    func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTick)
        lastTick = now
        inboxCounter += dt
        if inboxCounter > 0.25 { inboxCounter = 0; inbox.poll() }

        let t = Date().timeIntervalSince(moodStart)

        // 끝난 뒤 오래 조용하면 원래대로, 더 오래면 잠
        secCounter += dt
        if secCounter > 1 { secCounter = 0; refreshAll(); resolveDesktop(); keepVisible() } // 시간 글자 · 90초 접기 · 앱 제목
        if mood == .idle && Date().timeIntervalSince(lastActivity) > 600 {
            // 자기 전에 하품 한 번
            if !sleepYawned && poses["yawn"] != nil { sleepYawned = true; play("yawn") }
            else if action == nil { sleepYawned = false; setMood(.sleeping) }
        }

        // 몸 위치 (카드가 뜨면 위로)
        currentBaseY += (petBaseY - currentBaseY) * min(1, CGFloat(dt) * 10)

        var hop: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, tilt: CGFloat = 0
        let walking = canRoam && action == nil && walkEnabled && dragOffset == nil && updateWalk(dt)

        // 몸짓은 은은하게: 숨쉬기 + 상태 들어올 때 한 번만 폴짝
        let br = CGFloat(sin(now * 2.0))
        sy = 1 + br * 0.012; sx = 1 - br * 0.008
        func onceHop(_ height: CGFloat, _ dur: Double) -> CGFloat {
            t < dur ? sin(CGFloat(t / dur) * .pi) * height : 0
        }
        switch mood {
        case .idle:
            if walking {
                hop = walkStep(now)
            } else if let a = action {
                // 짧은 동작: 끝나면 쉬는 포즈로 (걷던 중이면 다시 걷기)
                let at = Date().timeIntervalSince(a.start)
                let env = CGFloat(sin(min(1, at / a.dur) * .pi)) // 0 → 1 → 0
                switch a.name {
                case "stretch": sx += env * 0.03; sy -= env * 0.015
                case "yawn": sy += env * 0.025
                case "scratch": hop = abs(CGFloat(sin(now * 14))) * 0.7 * env
                case "sniff": tilt = CGFloat(sin(now * 5)) * 0.012 * env
                case "happy": hop = at < 0.45 ? sin(CGFloat(at / 0.45) * .pi) * 8 : 0
                default: break
                }
                if at > a.dur {
                    action = nil
                    if targetX == nil { setPose(a.back ?? restPick()) }
                }
            } else if pose == "walk" {
                setPose(restPick())
            } else if Date() > nextIdleSwap {
                // 쉬는 동안 가끔 자세를 바꾸거나 짧은 동작 하나
                nextIdleSwap = Date().addingTimeInterval(Double.random(in: 8...16))
                if Double.random(in: 0..<1) < 0.6, let n = ["stretch", "yawn", "scratch", "sniff"]
                    .filter({ poses[$0] != nil }).randomElement() {
                    play(n, back: Bool.random() ? pose : nil)
                } else {
                    setPose(restPick())
                }
            }
            if pose == "belly" { tilt = CGFloat(sin(now * 1.4)) * 0.015 }
        case .working:
            // 가끔 일어나 돌아다니다가 다시 노트북으로
            if walking { hop = walkStep(now) }
            else { if pose != "work" { setPose("work") }; hop = anims["work"] == nil ? abs(CGFloat(sin(now * 6))) * 0.8 : 0 }
        case .waiting:
            hop = onceHop(8, 0.4)
        case .done:
            hop = onceHop(12, 0.45)
            if walking { hop = walkStep(now) }
            else if t > 4 && (pose == "happy" || pose == "walk") { setPose("sit") }
        case .sleeping:
            sy = 1 + br * 0.02; sx = 1 - br * 0.01
        }
        if !walking { animTick(now) }
        // 옆모습 그림은 오른쪽을 보고 있으니 왼쪽으로 갈 때만 뒤집는다
        let flip: CGFloat = (PetController.sidePoses.contains(pose) && facing < 0) ? -1 : 1
        _ = poseFlip

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cx = winW / 2 + walkOff
        petLayer.position = CGPoint(x: cx, y: currentBaseY + 10 + hop)
        petLayer.setAffineTransform(CGAffineTransform(rotationAngle: tilt))
        bodyLayer.setAffineTransform(CGAffineTransform(scaleX: sx * flip, y: sy))
        let shW = petW * 0.72 * (1 - hop / 90)
        shadowLayer.bounds = CGRect(x: 0, y: 0, width: shW, height: 12 * (1 - hop / 90))
        shadowLayer.shadowPath = CGPath(ellipseIn: shadowLayer.bounds.insetBy(dx: 6, dy: 2), transform: nil)
        shadowLayer.position = CGPoint(x: cx + petW * 0.05, y: currentBaseY + 13)
        shadowLayer.opacity = 0 // 그림자 없음 (스티커만)
        let top = currentBaseY + 10 + petSize
        // 좁은 포즈에서도 얼굴을 가리지 않게 옆으로 비켜서
        bubblePos = CGPoint(x: cx + min(max(petW * 0.42, 48), 72), y: top - 6 + hop * 0.6)
        // 말풍선은 전부 같은 자리 (하나만 옮기면 나머지가 창 왼쪽 아래 구석에 떠서 잘려 보임)
        fxLayer.sublayers?.filter { $0.name == "bubble" || $0.name == "bubbleT" }.forEach { $0.position = bubblePos }
        chevron.position = CGPoint(x: cx + petW * 0.5 + 8, y: top - 24)
        // 점은 머리 왼쪽 위 (오른쪽은 말풍선 자리)
        pinWarn.position = CGPoint(x: cx - petW * 0.28, y: top + 2)
        pinOk.position = CGPoint(x: cx - petW * 0.28 + (pinWarn.isHidden ? 0 : 26), y: top + 2)
        CATransaction.commit()

        // 창 위치
        if dragOffset == nil {
            let vf = petScreen()
            // 창이 화면 밖이나 두 화면 사이에 걸치면 잘리니 한 화면 안에서만
            posX = min(max(posX, vf.minX), vf.maxX - winW)
            posY = clampY(posY, vf)
            panel.setFrameOrigin(NSPoint(x: posX.rounded(), y: (posY - PetController.floorPad).rounded()))
        }
        updateMouseThrough()
    }
    var inboxCounter: Double = 0
    var secCounter: Double = 0
    var nextIdleSwap = Date().addingTimeInterval(30)

    // 오른쪽을 보는 옆모습 포즈
    static let sidePoses: Set<String> = ["walk", "stretch", "sniff", "look"]

    // 쉬는 포즈: 지금 것 빼고 가중치로 하나
    func restPick() -> String {
        let pool: [(String, Int)] = [("lie", 3), ("sit", 3), ("ball", 2), ("look", 2), ("belly", 1)]
        let ok = pool.filter { poses[$0.0] != nil && $0.0 != pose }
        let total = ok.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return "lie" }
        var r = Int.random(in: 0..<total)
        for (n, w) in ok { if r < w { return n }; r -= w }
        return "lie"
    }

    // 짧은 동작 (몇 초 뒤 쉬는 포즈로)
    struct Action { let name: String; let start: Date; let dur: Double; let back: String? }
    var action: Action?
    var sleepYawned = false
    func play(_ name: String, back: String? = nil) {
        guard poses[name] != nil else { return }
        let dur: [String: Double] = ["stretch": 3.5, "yawn": 2.8, "scratch": 3.2, "sniff": 4, "happy": 3]
        action = Action(name: name, start: Date(), dur: dur[name] ?? 3, back: back)
        if Bool.random() && !PetController.sidePoses.contains(pose) { facing = Bool.random() ? 1 : -1 }
        setPose(name)
    }

    // 높이: 바닥부터 머리가 메뉴 막대에 닿기 전까지 (창 윗부분은 말풍선 자리라 화면 위로 나가도 됨)
    // 바닥 16pt 안으로 내려놓으면 바닥에 붙인다
    func clampY(_ y: CGFloat, _ vf: NSRect) -> CGFloat {
        let v = min(max(y, vf.minY), vf.maxY - 140)
        return v - vf.minY < 16 ? vf.minY : v
    }

    // 창 가운데가 들어 있는 화면. 두 화면에 걸친 창은 한쪽에만 그려져 잘린다
    func petScreen(at x: CGFloat? = nil) -> NSRect {
        let px = x ?? (posX + winW / 2)
        let s = NSScreen.screens.first { $0.frame.minX <= px && px < $0.frame.maxX } ?? panel.screen ?? NSScreen.main!
        return s.visibleFrame
    }

    // 다음 산책까지 쉬는 시간: 놀 때는 자주, 일할 때는 노트북 좀 두드리다가
    func restSpan() -> Double {
        switch mood {
        case .working: return Double.random(in: 15...30)
        case .done: return Double.random(in: 8...15)
        default: return Double.random(in: 4...10)
        }
    }

    // 걸어 다녀도 되는 상태: 놀 때 · 일할 때 · 끝나고 기뻐한 뒤 (확인 필요 · 잘 때는 제자리)
    var canRoam: Bool {
        switch mood {
        case .idle, .working: return true
        case .done: return Date().timeIntervalSince(moodStart) > 4
        default: return false
        }
    }

    // 산책: 창(기준점)은 그대로, 머털이만 창 안에서 왔다 갔다. 걷고 있으면 true
    var walkOff: CGFloat = 0
    var walkRange: CGFloat { max(0, min(80, (winW - petW) / 2 - 12)) }
    func updateWalk(_ dt: Double) -> Bool {
        walkOff = min(max(walkOff, -walkRange), walkRange) // 넓은 포즈로 바뀌면 안으로
        if let tx = targetX {
            let d = tx - walkOff
            if abs(d) < 1.5 { targetX = nil; restUntil = Date().addingTimeInterval(abs(walkOff) > 4 ? Double.random(in: 2...5) : restSpan()); return false }
            facing = d > 0 ? 1 : -1
            // 걷다가 가끔 멈춰서 킁킁
            if mood == .idle && poses["sniff"] != nil && Double.random(in: 0..<1) < dt / 14 { play("sniff"); return false }
            walkOff += (d > 0 ? 1 : -1) * min(abs(d), CGFloat(dt) * 22)
            return true
        }
        if Date() > restUntil {
            // 기준점 = 상태 카드 가운데. 옆으로 조금 나갔다가 다시 가운데로 돌아와 쉰다
            if abs(walkOff) > 4 { targetX = 0 }
            else { targetX = min(CGFloat.random(in: 25...60), walkRange) * (Bool.random() ? 1 : -1) }
        }
        return false
    }

    // 펫·카드 위에서만 클릭을 받고 나머지는 뒤로 통과
    func updateMouseThrough() {
        let m = NSEvent.mouseLocation
        let f = panel.frame
        let local = NSPoint(x: m.x - f.minX, y: m.y - f.minY)
        let petRect = CGRect(x: winW / 2 + walkOff - petW / 2, y: currentBaseY + 10, width: petW, height: petH)
        let overCard = cardShown && card.frame.contains(local)
        let overList = hoverList && listView.frame.insetBy(dx: -4, dy: -4).contains(local)
        let over = petRect.contains(local) || overCard || overList || pinRect.contains(local)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }

        // 세션이 둘 이상일 때 카드에 마우스를 올리면 목록으로
        let now = CACurrentMediaTime()
        if (overCard || overList) && visibleCount > 1 && !dragMoved {
            hoverLeaveAt = nil
            setHover(true)
            listView.highlight(at: local)
        } else if hoverList {
            if hoverLeaveAt == nil { hoverLeaveAt = now }
            if now - hoverLeaveAt! > 0.3 { hoverLeaveAt = nil; setHover(false) }
        }
    }

    // 머리 위 점 자리 (보일 때만)
    var pinRect: CGRect {
        guard !pinWarn.isHidden || !pinOk.isHidden else { return .zero }
        return pinWarn.frame.union(pinOk.frame).insetBy(dx: -6, dy: -6)
    }

    // MARK: 마우스

    func mouse(_ e: NSEvent) {
        let p = e.locationInWindow
        switch e.type {
        case .leftMouseDown:
            dragOffset = NSPoint(x: NSEvent.mouseLocation.x - panel.frame.minX, y: NSEvent.mouseLocation.y - posY)
            dragMoved = false
        case .leftMouseDragged:
            guard let off = dragOffset else { return }
            dragMoved = true
            // 끄는 중에도 마우스가 있는 화면 안에서만 (화면 사이에 걸치지 않게)
            let vf = petScreen(at: NSEvent.mouseLocation.x)
            posX = min(max(NSEvent.mouseLocation.x - off.x, vf.minX), vf.maxX - winW)
            posY = clampY(NSEvent.mouseLocation.y - off.y, vf)
            panel.setFrameOrigin(NSPoint(x: posX.rounded(), y: (posY - PetController.floorPad).rounded()))
            targetX = nil
        case .leftMouseUp:
            defer { dragOffset = nil }
            if dragMoved {
                restUntil = Date().addingTimeInterval(8)
                UserDefaults.standard.set([Double(posX), Double(posY)], forKey: "petPos")
                return
            }
            if hoverList && listView.frame.contains(p) {
                openSession(listView.row(at: p)); return
            }
            if cardShown && card.frame.contains(p) {
                openSession(topID); return
            }
            if pinRect.contains(p) || (!cardShown && cardCollapsed && visibleCount > 0) {
                cardCollapsed = false
                // 90초 지난 준비됨도 다시 카드로
                if let top = visibleSessions().first, isStale(top) { sessions[top.id]?.finished = Date() }
                refreshAll(); return
            }
            // 머털이 쓰다듬기
            if mood == .sleeping { lastActivity = Date(); setMood(.idle) }
            else if mood == .idle && action == nil && targetX == nil { play("happy") }
            bubble(symbol: "heart.fill", color: brandPink)
        default: break
        }
    }

    // macOS 14부터 뒤에 있는 앱의 activate()는 무시돼서, 사용자가 연 것처럼 워크스페이스로 연다
    func openClaude() { openApp(["com.anthropic.claudefordesktop", "com.anthropic.claude"]) }
    func openApp(_ ids: [String]) {
        for id in ids {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            return
        }
    }
}

// MARK: - 메뉴 막대

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pet: PetController!
    var status: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        // 한 마리만: 먼저 떠 있는 머털이가 있으면 나는 조용히 나간다
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: "kr.lizzy.meoteori").contains(where: {
            $0 != me && ($0.launchDate ?? .distantFuture) < (me.launchDate ?? .distantPast)
        }) { NSApp.terminate(nil); return }
        pet = PetController()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "머털이")
        let menu = NSMenu()
        menu.addItem(withTitle: "머털이 보이기/숨기기", action: #selector(toggle), keyEquivalent: "").target = self
        let walk = menu.addItem(withTitle: "산책하기", action: #selector(toggleWalk(_:)), keyEquivalent: "")
        walk.target = self; walk.state = .on
        menu.addItem(.separator())
        for (t, m) in [("미리보기: 작업 중", "working"), ("미리보기: 확인 필요", "waiting"), ("미리보기: 준비됨", "done")] {
            let it = menu.addItem(withTitle: t, action: #selector(test(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = m
        }
        menu.addItem(withTitle: "미리보기: 여러 세션", action: #selector(testMany), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    @objc func toggle() {
        pet.hiddenByUser = pet.panel.isVisible
        pet.hiddenByUser ? pet.panel.orderOut(nil) : pet.panel.orderFrontRegardless()
    }
    @objc func toggleWalk(_ s: NSMenuItem) { pet.walkEnabled.toggle(); s.state = pet.walkEnabled ? .on : .off }
    @objc func testMany() {
        for (sid, t, m, ago) in [("p1", "리드폼 약관 문구 대조", "working", 180.0), ("p2", "타이어 랜딩 사진 정리", "done", 120.0),
                                 ("p3", "머털이 포즈 다듬기", "waiting", 0.0)] {
            pet.handle(event: ["hook_event_name": "MeoteoriTest", "session_id": sid, "title": t, "mood": m, "ago": ago, "cwd": ""])
        }
    }
    @objc func test(_ s: NSMenuItem) {
        pet.handle(event: ["hook_event_name": "MeoteoriTest", "session_id": "preview",
                           "title": "유튜브 정리", "mood": s.representedObject as! String, "cwd": ""])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
