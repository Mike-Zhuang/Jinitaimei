import Foundation
import os

public final class LibrarySpaceAPI {
    private let apiHost = "https://space.tongji.edu.cn"
    private let logger = Logger(subsystem: "com.jinitaimei.app", category: "LibrarySpaceAPI")
    private let store: CredentialStore
    private let session: URLSession

    public init(store: CredentialStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
    }

    public func fetchOverview() async throws -> LibrarySpaceOverviewResult {
        try await withLibrarySpaceAuthRetry { [self] in
            try await fetchOverviewOnce()
        }
    }

    public func fetchSeatAreaDetail(area: LibrarySpaceArea) async throws -> LibrarySeatAreaDetail {
        try await withLibrarySpaceAuthRetry { [self] in
            try await fetchSeatAreaDetailOnce(area: area)
        }
    }

    public func fetchSeminarRoomDetail(room: LibrarySpaceRoom) async throws -> LibrarySeminarRoomDetail {
        try await withLibrarySpaceAuthRetry { [self] in
            try await fetchSeminarRoomDetailOnce(room: room)
        }
    }

    private func fetchOverviewOnce() async throws -> LibrarySpaceOverviewResult {
        _ = try await ensureToken()
        try await warmUpReserveIndex()

        let seatPayload: QuickSelectResponse = try await post(
            path: "/reserve/index/quickSelect",
            body: QuickSelectRequest(id: "1", date: Self.todayString(), categoryIds: ["1"], members: 0)
        )
        let roomPayload: QuickSelectResponse = try await post(
            path: "/reserve/index/quickSelect",
            body: QuickSelectRequest(id: "2", date: Self.todayString(), categoryIds: nil, members: 0)
        )
        guard seatPayload.isSuccess, let seatData = seatPayload.data else {
            throw AuthError.loginFlowFailed(seatPayload.msg.isEmpty ? "图书馆座位概览响应异常" : seatPayload.msg)
        }
        guard roomPayload.isSuccess, let roomData = roomPayload.data else {
            throw AuthError.loginFlowFailed(roomPayload.msg.isEmpty ? "图书馆研习室概览响应异常" : roomPayload.msg)
        }

        let libraries = seatData.premises.map {
            LibrarySpaceLibrary(
                id: $0.id,
                name: $0.name,
                totalSeats: $0.totalNum.intValue,
                freeSeats: $0.freeNum.intValue
            )
        }
        let libraryById = Dictionary(uniqueKeysWithValues: libraries.map { ($0.id, $0) })

        let floorById = Dictionary(uniqueKeysWithValues: seatData.storey.map { ($0.id, $0) })
        let roomFloorById = Dictionary(uniqueKeysWithValues: roomData.storey.map { ($0.id, $0) })
        let roomLibraryById = Dictionary(uniqueKeysWithValues: roomData.premises.map { ($0.id, $0) })

        let areas = seatData.area.map { raw in
            let floor = floorById[raw.parentId]
            let library = floor.flatMap { libraryById[$0.parentId] }
            return LibrarySpaceArea(
                id: raw.id,
                libraryId: library?.id ?? "",
                libraryName: library?.name ?? Self.firstComponent(raw.nameMerge),
                floorId: floor?.id ?? raw.parentId,
                floorName: floor?.name ?? Self.secondComponent(raw.nameMerge),
                name: raw.name,
                mergedName: raw.nameMerge,
                typeName: raw.typeName,
                totalSeats: raw.totalNum.intValue,
                freeSeats: raw.freeNum.intValue
            )
        }

        let rooms = roomData.area.map { raw in
            let floor = roomFloorById[raw.parentId]
            let libraryRaw = floor.flatMap { roomLibraryById[$0.parentId] }
            return LibrarySpaceRoom(
                id: raw.id,
                libraryId: libraryRaw?.id ?? "",
                libraryName: libraryRaw?.name ?? Self.firstComponent(raw.nameMerge),
                floorId: floor?.id ?? raw.parentId,
                floorName: floor?.name ?? Self.secondComponent(raw.nameMerge),
                name: raw.name,
                mergedName: raw.nameMerge,
                typeName: raw.typeName
            )
        }

        return LibrarySpaceOverviewResult(libraries: libraries, areas: areas, rooms: rooms)
    }

    private func fetchSeatAreaDetailOnce(area: LibrarySpaceArea) async throws -> LibrarySeatAreaDetail {
        _ = try await ensureToken()

        async let labelsRaw: SeatLabelResponse = post(path: "/api/seat/label", body: EmptyAuthorizedRequest())
        async let mapRaw: SeatMapResponse = post(path: "/api/seat/map", body: IdRequest(id: area.id))
        let datePayload: SeatDateResponse = try await post(path: "/api/Seat/date", body: SeatDateRequest(buildId: area.id))

        guard datePayload.isSuccess else {
            throw AuthError.loginFlowFailed(datePayload.msg.isEmpty ? "座位开放时间响应异常" : datePayload.msg)
        }
        let allSegments: [(day: String, time: SeatTimeRaw)] = (datePayload.data ?? []).flatMap { day in
            day.times.map { (day: day.day, time: $0) }
        }
        let segment = allSegments.first { $0.time.status == 1 } ?? allSegments.first

        guard let segment else {
            throw AuthError.loginFlowFailed("当前区域暂无可查询时段")
        }

        async let seatsRaw: SeatListResponse = post(
            path: "/api/Seat/seat",
            body: SeatRequest(
                area: area.id,
                segment: segment.time.id,
                day: segment.day,
                startTime: segment.time.start,
                endTime: segment.time.end
            )
        )

        let labelPayload = try await labelsRaw
        let mapPayload = try await mapRaw
        let seatPayload = try await seatsRaw
        guard labelPayload.isSuccess, mapPayload.isSuccess, seatPayload.isSuccess else {
            throw AuthError.loginFlowFailed("座位状态响应异常")
        }

        let labels = (labelPayload.data ?? []).map {
            LibrarySeatLabel(id: $0.id, name: $0.name)
        }
        let rawSeats: [SeatRaw] = seatPayload.data ?? []
        let seats = rawSeats.map { raw in
            let base = LibrarySeat(
                id: raw.id,
                number: raw.no.nilIfEmpty ?? raw.name,
                name: raw.name,
                x: raw.pointX.doubleValue,
                y: raw.pointY.doubleValue,
                width: raw.width.doubleValue,
                height: raw.height.doubleValue,
                status: raw.status,
                statusName: raw.statusName,
                areaName: raw.areaName,
                labels: raw.inLabelNames
            )
            let localTags = LibrarySeatLocalTagger.tags(for: base, in: area)
            return LibrarySeat(
                id: base.id,
                number: base.number,
                name: base.name,
                x: base.x,
                y: base.y,
                width: base.width,
                height: base.height,
                status: base.status,
                statusName: base.statusName,
                areaName: base.areaName,
                labels: Array(Set(base.labels + localTags)).sorted()
            )
        }

        return LibrarySeatAreaDetail(
            area: area,
            labels: labels,
            mapAssets: mapPayload.data?.asAssets ?? LibrarySeatMapAssets(
                freeURL: nil, useURL: nil, leaveURL: nil, bookURL: nil, closeURL: nil, notURL: nil, configURL: nil
            ),
            segments: (datePayload.data ?? []).flatMap { day in
                day.times.map {
                    LibrarySeatTimeSegment(id: $0.id, day: day.day, startTime: $0.start, endTime: $0.end)
                }
            },
            seats: seats
        )
    }

    private func fetchSeminarRoomDetailOnce(room: LibrarySpaceRoom) async throws -> LibrarySeminarRoomDetail {
        _ = try await ensureToken()

        async let detailRaw: SeminarDetailResponse = post(
            path: "/api/Seminar/detail",
            body: SeminarDetailRequest(id: room.id, day: Self.todayString())
        )
        async let availabilityRaw: SeminarAvailabilityResponse = post(
            path: "/api/Seminar/v1seminar",
            body: SeminarAvailabilityRequest(room: room.id, area: room.libraryId)
        )

        let detailPayload = try await detailRaw
        let availabilityPayload = try await availabilityRaw
        guard detailPayload.isSuccess, availabilityPayload.isSuccess else {
            throw AuthError.loginFlowFailed("研习室时段响应异常")
        }

        let memberCount = detailPayload.data?.membercount ?? ""
        let parsedPeople = Self.peopleRange(memberCount)
        let availabilities = (availabilityPayload.data?.list ?? [])
            .prefix(3)
            .map { raw in
                let info = raw.info
                let minPeople = info.minPerson.intValue
                let maxPeople = info.maxPerson.intValue
                let segments = info.list.map {
                    LibrarySeminarFreeSegment(
                        id: $0.id,
                        beginText: Self.timeText($0.beginTimestamp),
                        endText: Self.timeText($0.endTimestamp),
                        beginMinute: $0.beginNum,
                        endMinute: $0.endNum
                    )
                }
                return LibrarySeminarRoomAvailability(
                    id: "\(room.id)-\(raw.date)",
                    roomId: room.id,
                    date: raw.date,
                    openStartMinute: info.startTime,
                    openEndMinute: info.endTime,
                    minMinutes: info.minTime,
                    maxMinutes: info.maxTime,
                    minPeople: minPeople == 0 ? parsedPeople.min : minPeople,
                    maxPeople: maxPeople == 0 ? parsedPeople.max : maxPeople,
                    freeSegments: segments
                )
            }

        return LibrarySeminarRoomDetail(
            room: room,
            memberCountText: memberCount,
            minPeople: parsedPeople.min,
            maxPeople: parsedPeople.max,
            availabilities: Array(availabilities)
        )
    }

    private func warmUpReserveIndex() async throws {
        let invitationPayload: InvitationResponse = try await post(
            path: "/api/member/invitations",
            body: EmptyAuthorizedRequest()
        )
        guard invitationPayload.isSuccess else {
            throw AuthError.loginFlowFailed(invitationPayload.msg.isEmpty ? "图书馆用户状态初始化异常" : invitationPayload.msg)
        }

        let seatPayload: ReserveIndexResponse = try await post(
            path: "/reserve/index/index",
            body: IdRequest(id: "1")
        )
        guard seatPayload.isSuccess else {
            throw AuthError.loginFlowFailed(seatPayload.msg.isEmpty ? "图书馆座位入口响应异常" : seatPayload.msg)
        }

        let roomPayload: ReserveIndexResponse = try await post(
            path: "/reserve/index/index",
            body: IdRequest(id: "2")
        )
        guard roomPayload.isSuccess else {
            throw AuthError.loginFlowFailed(roomPayload.msg.isEmpty ? "图书馆研习室入口响应异常" : roomPayload.msg)
        }
    }

    private func ensureToken() async throws -> String {
        if let token = store.get(CredentialStore.Keys.librarySpaceBearerToken), !token.isEmpty {
            return token
        }

        log("本地无图书馆 JWT，先触发续期")
        let renewed = await LibrarySpaceAuthCoordinator.shared.renewIfPossible()
        guard renewed,
              let token = store.get(CredentialStore.Keys.librarySpaceBearerToken),
              !token.isEmpty else {
            throw AuthError.notLoggedIn("图书馆系统登录失效，请稍后重试")
        }
        return token
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        guard let token = store.get(CredentialStore.Keys.librarySpaceBearerToken), !token.isEmpty else {
            log("POST \(path) token=false")
            throw AuthError.notLoggedIn("图书馆系统登录失效，请稍后重试")
        }

        let url = URL(string: "\(apiHost)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiHost, forHTTPHeaderField: "Origin")
        request.setValue("\(apiHost)/h5/", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("zh", forHTTPHeaderField: "lang")
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )

        let bodyData = try authorizedBodyData(body: body, token: token, path: path)
        request.httpBody = bodyData
        // 实测：后端要求 authorization 同时出现在 HTTP 头中，仅放 body 会被判为「您尚未登录」(code=10001)。
        request.setValue("bearer\(token)", forHTTPHeaderField: "authorization")
        log("POST \(path) token=true len=\(token.count)")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.loginFlowFailed("响应异常") }
        if http.statusCode == 401 || http.statusCode == 403 {
            if let fallback: T = try await tryPostFromWebView(path: path, bodyData: bodyData, reason: "HTTP \(http.statusCode)") {
                return fallback
            }
            clearTokenAfterAuthFailure(path: path, reason: "HTTP \(http.statusCode)")
            throw AuthError.expired("图书馆凭证已失效")
        }
        logResponse(path: path, statusCode: http.statusCode, data: data)
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.loginFlowFailed("HTTP \(http.statusCode)")
        }
        if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data),
           Self.responseRequiresLogin(code: status.code, msg: status.msg) {
            if let fallback: T = try await tryPostFromWebView(path: path, bodyData: bodyData, reason: "业务响应未登录") {
                return fallback
            }
            clearTokenAfterAuthFailure(path: path, reason: "业务响应未登录")
            throw AuthError.expired("图书馆系统登录失效，请稍后重试")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func tryPostFromWebView<T: Decodable>(
        path: String,
        bodyData: Data,
        reason: String
    ) async throws -> T? {
        log("\(path) URLSession 被拒绝（\(reason)），尝试 WebView 同源请求兜底")
        let result: LibrarySpaceAuthCoordinator.WebFetchResult
        do {
            result = try await LibrarySpaceAuthCoordinator.shared.postFromAuthenticatedWebView(
                path: path,
                bodyData: bodyData
            )
        } catch {
            log("\(path) WebView 同源请求不可用：\(error.localizedDescription)")
            return nil
        }

        logResponse(path: "\(path)#webview", statusCode: result.statusCode, data: result.data)
        guard (200..<300).contains(result.statusCode) else {
            return nil
        }
        if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: result.data),
           Self.responseRequiresLogin(code: status.code, msg: status.msg) {
            return nil
        }
        return try JSONDecoder().decode(T.self, from: result.data)
    }

    private func authorizedBodyData<Body: Encodable>(body: Body, token: String, path: String) throws -> Data {
        let rawData = try JSONEncoder().encode(body)
        let rawObject = try JSONSerialization.jsonObject(with: rawData, options: [])
        var dictionary = rawObject as? [String: Any] ?? [:]
        dictionary["authorization"] = "bearer\(token)"
        let keyList = dictionary.keys.sorted().joined(separator: ",")
        log("请求体 \(path) keys=\(keyList)")
        return try JSONSerialization.data(withJSONObject: dictionary, options: [])
    }

    private func clearTokenAfterAuthFailure(path: String, reason: String) {
        store.remove(CredentialStore.Keys.librarySpaceBearerToken)
        log("\(path) 判定图书馆 JWT 失效：\(reason)，已清除本地 token")
    }

    private func logResponse(path: String, statusCode: Int, data: Data) {
        if let status = try? JSONDecoder().decode(StatusEnvelope.self, from: data) {
            let msg = Self.redactedMessage(status.msg)
            log("响应 \(path) HTTP \(statusCode) code=\(status.code.map(String.init) ?? "nil") msg=\(msg)")
        } else {
            log("响应 \(path) HTTP \(statusCode) 无法解码业务状态")
        }
    }

    private func log(_ message: String) {
        let line = "[LibrarySpaceAPI] \(message)"
        logger.info("\(line, privacy: .public)")
        print(line)
    }

    private static func responseRequiresLogin(code: Int?, msg: String?) -> Bool {
        if code == 401 || code == 403 { return true }
        let normalized = (msg ?? "").lowercased()
        if normalized.isEmpty { return false }
        return normalized.contains("未登录") ||
               normalized.contains("未登陆") ||
               normalized.contains("尚未登录") ||
               normalized.contains("请登录") ||
               normalized.contains("登录失效") ||
               normalized.contains("token") ||
               normalized.contains("unauthorized")
    }

    private static func redactedMessage(_ msg: String?) -> String {
        let value = msg ?? ""
        guard value.count > 80 else { return value.isEmpty ? "<empty>" : value }
        return String(value.prefix(80)) + "..."
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func firstComponent(_ value: String) -> String {
        value.components(separatedBy: "-").first ?? ""
    }

    private static func secondComponent(_ value: String) -> String {
        let parts = value.components(separatedBy: "-")
        return parts.count > 1 ? parts[1] : ""
    }

    private static func peopleRange(_ value: String) -> (min: Int, max: Int) {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        if parts.count == 2 { return (parts[0], parts[1]) }
        if let first = parts.first { return (first, first) }
        return (0, 0)
    }

    private static func timeText(_ timestamp: String) -> String {
        guard timestamp.count >= 16 else { return timestamp }
        return String(timestamp.dropFirst(11).prefix(5))
    }
}

private struct EmptyAuthorizedRequest: Encodable {}

private struct QuickSelectRequest: Encodable {
    let id: String
    let date: String
    let categoryIds: [String]?
    let members: Int

    enum CodingKeys: String, CodingKey {
        case id, date, categoryIds, members
    }
}

private struct IdRequest: Encodable {
    let id: String
}

private struct SeatDateRequest: Encodable {
    let buildId: String

    enum CodingKeys: String, CodingKey {
        case buildId = "build_id"
    }
}

private struct SeatRequest: Encodable {
    let area: String
    let segment: String
    let day: String
    let startTime: String
    let endTime: String
}

private struct SeminarDetailRequest: Encodable {
    let id: String
    let day: String
}

private struct SeminarAvailabilityRequest: Encodable {
    let room: String
    let area: String
}

private struct BaseResponse<DataType: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: DataType?

    var isSuccess: Bool { code == 0 || code == 1 || code == 200 }

    enum CodingKeys: String, CodingKey {
        case code, msg, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // code 在不同接口可能是 Int 或字符串数字，统一兼容解析
        if let intCode = try? container.decode(Int.self, forKey: .code) {
            code = intCode
        } else if let stringCode = try? container.decode(String.self, forKey: .code),
                  let intCode = Int(stringCode) {
            code = intCode
        } else {
            code = -1
        }
        // 部分接口（如 invitations、seat/map）成功时不返回 msg，缺失时按空串处理，避免整条链路解码中断
        msg = (try? container.decode(String.self, forKey: .msg)) ?? ""
        // 用 decodeIfPresent 保留真实的 data 结构不匹配错误，仅容忍 data 缺失/为 null
        data = try container.decodeIfPresent(DataType.self, forKey: .data)
    }
}

private typealias InvitationResponse = BaseResponse<JSONValue>
private typealias ReserveIndexResponse = BaseResponse<JSONValue>
private struct StatusEnvelope: Decodable {
    let code: Int?
    let msg: String?

    enum CodingKeys: String, CodingKey {
        case code, msg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let intCode = try? container.decode(Int.self, forKey: .code) {
            code = intCode
        } else if let stringCode = try? container.decode(String.self, forKey: .code) {
            code = Int(stringCode)
        } else {
            code = nil
        }
        msg = try? container.decode(String.self, forKey: .msg)
    }
}

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .number(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }
        if let container = try? decoder.container(keyedBy: DynamicJSONKey.self) {
            var object: [String: JSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }
        var container = try decoder.unkeyedContainer()
        var array: [JSONValue] = []
        while !container.isAtEnd {
            array.append(try container.decode(JSONValue.self))
        }
        self = .array(array)
    }
}

private struct DynamicJSONKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private typealias QuickSelectResponse = BaseResponse<QuickSelectData>
private typealias SeatLabelResponse = BaseResponse<[SeatLabelRaw]>
private typealias SeatDateResponse = BaseResponse<[SeatDateRaw]>
private typealias SeatMapResponse = BaseResponse<SeatMapRaw>
private typealias SeatListResponse = BaseResponse<[SeatRaw]>
private typealias SeminarDetailResponse = BaseResponse<SeminarDetailRaw>
private typealias SeminarAvailabilityResponse = BaseResponse<SeminarAvailabilityData>

private struct QuickSelectData: Decodable {
    let premises: [SpaceNodeRaw]
    let storey: [SpaceNodeRaw]
    let area: [SpaceNodeRaw]
}

private struct SpaceNodeRaw: Decodable {
    let id: String
    let name: String
    let nameMerge: String
    let parentId: String
    let typeName: String
    let totalNum: String
    let freeNum: String

    enum CodingKeys: String, CodingKey {
        case id, name, nameMerge, parentId, typeName = "type_name", totalNum = "total_num", freeNum = "free_num"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.flexString(.id)
        name = try container.flexString(.name)
        nameMerge = try container.flexString(.nameMerge)
        parentId = try container.flexString(.parentId)
        typeName = try container.flexString(.typeName)
        totalNum = try container.flexString(.totalNum)
        freeNum = try container.flexString(.freeNum)
    }
}

private struct SeatLabelRaw: Decodable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey { case id, name }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.flexString(.id)
        name = try container.flexString(.name)
    }
}

private struct SeatDateRaw: Decodable {
    let day: String
    let times: [SeatTimeRaw]
}

private struct SeatTimeRaw: Decodable {
    let id: String
    let status: Int
    let start: String
    let end: String

    enum CodingKeys: String, CodingKey { case id, status, start, end }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.flexString(.id)
        status = try container.flexString(.status).intValue
        start = try container.flexString(.start)
        end = try container.flexString(.end)
    }
}

private struct SeatMapRaw: Decodable {
    let free: String?
    let use: String?
    let leave: String?
    let book: String?
    let close: String?
    let not: String?
    let config: String?

    var asAssets: LibrarySeatMapAssets {
        LibrarySeatMapAssets(
            freeURL: free.flatMap(URL.init(string:)),
            useURL: use.flatMap(URL.init(string:)),
            leaveURL: leave.flatMap(URL.init(string:)),
            bookURL: book.flatMap(URL.init(string:)),
            closeURL: close.flatMap(URL.init(string:)),
            notURL: not.flatMap(URL.init(string:)),
            configURL: config.flatMap(URL.init(string:))
        )
    }
}

private struct SeatRaw: Decodable {
    let id: String
    let no: String
    let name: String
    let pointX: String
    let pointY: String
    let width: String
    let height: String
    let status: String
    let statusName: String
    let areaName: String
    let inLabelNames: [String]

    enum CodingKeys: String, CodingKey {
        case id, no, name, pointX = "point_x", pointY = "point_y", width, height, status, statusName = "status_name", areaName = "area_name", inLabel = "in_label"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.flexString(.id)
        no = try container.flexString(.no)
        name = try container.flexString(.name)
        pointX = try container.flexString(.pointX)
        pointY = try container.flexString(.pointY)
        width = try container.flexString(.width)
        height = try container.flexString(.height)
        status = try container.flexString(.status)
        statusName = try container.flexString(.statusName)
        areaName = try container.flexString(.areaName)
        inLabelNames = (try? container.decode([String].self, forKey: .inLabel)) ??
                       (try? container.decode(String.self, forKey: .inLabel).split(separator: ",").map { String($0) }) ??
                       []
    }
}

private struct SeminarDetailRaw: Decodable {
    let membercount: String
}

private struct SeminarAvailabilityData: Decodable {
    let list: [SeminarDateRaw]
}

private struct SeminarDateRaw: Decodable {
    let date: String
    let info: SeminarInfoRaw
}

private struct SeminarInfoRaw: Decodable {
    let startTime: Int
    let endTime: Int
    let minTime: Int
    let maxTime: Int
    let minPerson: String
    let maxPerson: String
    let list: [SeminarFreeRaw]
}

private struct SeminarFreeRaw: Decodable {
    let id: String
    let beginTimestamp: String
    let endTimestamp: String
    let beginNum: Int
    let endNum: Int
}

private extension KeyedDecodingContainer {
    func flexString(_ key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        if (try? decodeNil(forKey: key)) == true { return "" }
        return ""
    }
}

private extension String {
    var intValue: Int { Int(self) ?? 0 }
    var doubleValue: Double { Double(self) ?? 0 }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
