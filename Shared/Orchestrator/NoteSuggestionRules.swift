import Foundation

// The tables behind `NoteSuggester`: what to look for (Traditional Chinese, Simplified Chinese and English) and what
// to suggest. Item texts are data in both languages, inline (a chip shows its text verbatim and the notes keep it as
// typed), so the String Catalog has no keys for them. docs/GEMINI_FUNCTION_CALLING.md §12 lists the kinds of event;
// keep it, and the web prototype's copy of these tables, in step.

extension NoteSuggester {
    // MARK: Building blocks

    /// Words to look for in folded text (lower case, half width, no accents). Phrases (Chinese, or anything that is
    /// not a whole word such as "zoom.us") match anywhere; English patterns are ICU regular expressions in lower case
    /// that match whole words only (ASCII letters and digits around them end the match), so "gym" is not found in
    /// "gymnastics", "pool" not in "carpool", and "下午gym" still finds "gym".
    struct Matcher {
        let phrases: [String]
        let patterns: [String]
        let regex: NSRegularExpression?

        init(_ phrases: [String] = [], en patterns: [String] = []) {
            self.phrases = phrases.map { NoteSuggester.fold($0) }
            self.patterns = patterns
            if patterns.isEmpty {
                regex = nil
            } else {
                let pattern = "(?<![a-z0-9])(?:" + patterns.joined(separator: "|") + ")(?![a-z0-9])"
                regex = try? NSRegularExpression(pattern: pattern)
            }
        }

        /// Every phrase and pattern of `matchers`.
        static func any(_ matchers: Matcher...) -> Matcher {
            Matcher(matchers.flatMap { $0.phrases }, en: matchers.flatMap { $0.patterns })
        }

        /// False when the English patterns do not compile (a unit test checks every table).
        var isValid: Bool { patterns.isEmpty || regex != nil }

        func matches(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            for phrase in phrases where text.contains(phrase) { return true }
            guard let regex else { return false }
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    /// One suggestion in both languages.
    struct Item {
        /// Stable across languages: "rule.<id>" is the suggestion's id; one item is offered once.
        let id: String
        let en: String
        let zh: String
        /// Words that mean the notes already have it, in any language (both texts always count).
        let keys: [String]
        /// Only when this also matches the event.
        var onlyIf: Matcher? = nil
        /// Not when this matches the event.
        var unless: Matcher? = nil
        /// true: online events only; false: in person only.
        var online: Bool? = nil
        /// Only when this other kind of event matched too ("International driving permit" needs "abroad").
        var requires: String? = nil
        /// true: flights only ("Check in online"); false: never for a flight ("Have tickets ready" for the train).
        var flight: Bool? = nil

        func applies(in context: RuleContext, matched: Set<String>) -> Bool {
            if let onlyIf, !onlyIf.matches(context.all) { return false }
            if let unless, unless.matches(context.all) { return false }
            if let online, online != context.isOnline { return false }
            if let requires, !matched.contains(requires) { return false }
            if let flight, flight != context.isFlight { return false }
            return true
        }

        func isNoted(inNormalized notes: String) -> Bool {
            guard !notes.isEmpty else { return false }
            return ([en, zh] + keys).contains { text in
                NoteSuggester.isAlreadyNoted(normalizedText: NoteSuggester.normalized(text), inNormalized: notes)
            }
        }
    }

    /// A kind of event and what it may need.
    struct Category {
        enum Special {
            /// Decided by `RuleContext.isAbroad` (foreign places, the home country, flights).
            case abroad
            /// The triggers, or a flight or trip within the home country (`RuleContext.isDomesticTrip`).
            case domesticTravel
        }

        let id: String
        /// Any of these words.
        let triggers: Matcher
        /// Or both words of a pair.
        var pairs: [(Matcher, Matcher)] = []
        /// Never when any of these words is there.
        var excludes: Matcher? = nil
        /// Kinds of event left out when this one matches (yoga needs no running shoes).
        var supersedes: [String] = []
        /// Not for an online event (a video call is no trip).
        var inPersonOnly = false
        var special: Special? = nil
        /// Most useful first.
        let items: [Item]

        func matches(_ text: String) -> Bool {
            triggers.matches(text) || pairs.contains { $0.0.matches(text) && $0.1.matches(text) }
        }

        /// Whether `field` alone says something about this kind of event (for ranking the title first).
        func signals(in field: String) -> Bool {
            triggers.matches(field) || pairs.contains { $0.0.matches(field) || $0.1.matches(field) }
        }
    }

    /// One event as the rules see it.
    struct RuleContext {
        let title: String
        let location: String
        let notes: String
        /// Title, place and notes together.
        let all: String
        /// Title and place: what the event is. Exclusions count here; in the notes only when the notes alone say
        /// what kind of event it is (`excludes(_:unlessSaidBy:)`), so "Flight to Tokyo" with "Dad picks me up" or
        /// "健身" with "記得買水" in the notes keeps its suggestions.
        let identity: String
        let isOnline: Bool
        /// Two days or more (all-day), or 20 hours or more: a trip rather than an appointment.
        let isMultiDay: Bool
        /// A flight: "機場", "班機", "flight", or "飛" / "fly" with a place ("飛東京", "fly to Tokyo").
        let isFlight: Bool
        /// Outside the user's country: "出國", a foreign place with a travel word ("東京旅遊", "Trip to Tokyo"), a
        /// flight to a foreign place or to no place in the user's country, a multi-day event at a foreign place.
        /// Never for picking someone up ("接機"), "國內" / "domestic" or an online event.
        let isAbroad: Bool
        /// Within the user's country: a flight to a place there ("澎湖班機"), or a trip word with one ("飛澎湖").
        let isDomesticTrip: Bool

        var fields: [String] { [title, location, notes] }

        /// `matcher` (an exclusion) is in the title or place, or in the notes when `category` is not already
        /// recognised from the title or place.
        func excludes(_ matcher: Matcher, unlessSaidBy category: Category) -> Bool {
            matcher.matches(identity)
                || (matcher.matches(notes) && !category.signals(in: title) && !category.signals(in: location))
        }

        init(event: ScheduleEvent, notes rawNotes: String?, homeTimeZone: TimeZone) {
            let title = NoteSuggester.fold(event.title)
            let location = NoteSuggester.fold(event.location ?? "")
            // Smart Schedule's provenance line keeps what the user said, which helps; its fixed prefix does not.
            let notes = NoteSuggester.fold((rawNotes ?? "").replacingOccurrences(of: CalendarEventMapper.provenancePrefix,
                                                                                with: " "))
            let all = [title, location, notes].joined(separator: "\n")
            let identity = title + "\n" + location
            let isOnline = event.meetURL != nil || Words.online.matches(title + "\n" + location)
                || Words.onlineLinks.matches(all)
            let length = event.end.timeIntervalSince(event.start)
            let isMultiDay = event.isAllDay ? length >= 2 * 86_400 - 7_200 : length >= 20 * 3_600

            let home = Home(timeZone: homeTimeZone)
            let foreign = NoteSuggester.places.contains { !home.contains($0.region) && $0.matcher.matches(all) }
            let homePlace = NoteSuggester.places.contains { home.contains($0.region) && $0.matcher.matches(all) }
            // "飛輪" (spin class), "飛盤" (frisbee), "飛鏢" (darts) are no flight, even at a place.
            let flyText = NoteSuggester.withoutNotFlying(all)
            let flight = Words.flight.matches(all) || ((foreign || homePlace) && Words.fly.matches(flyText))
            // Addresses name the user's own cities all the time ("台北市…" for the gym): a place at home makes a trip
            // only with a clear travel word, or in the title with "去" / "go to" ("開車去台中").
            let homeTrip = (homePlace && Words.trip.matches(all))
                || (NoteSuggester.places.contains { home.contains($0.region) && $0.matcher.matches(title) }
                    && Words.headingTo.matches(NoteSuggester.withoutNotFlying(title)))
            // The title or place says it is a trip: then words in the notes ("pick me up", "book hotel", "吃拉麵")
            // do not undo it.
            let saysTrip = Words.flight.matches(identity) || Words.fly.matches(NoteSuggester.withoutNotFlying(identity))
                || Words.abroad.matches(identity) || Words.travelish.matches(identity) || NoteSuggester.foreignPlaces.matches(identity)
            func excluded(_ matcher: Matcher) -> Bool {
                matcher.matches(identity) || (!saysTrip && matcher.matches(notes))
            }
            let pickup = excluded(Words.pickup)
            let travelish = Words.travelish.matches(flyText) && !excluded(Words.notTravel)
            let foreignTrip = foreign && (travelish || flight || isMultiDay)
            let isAbroad = !isOnline && !pickup && !excluded(Words.domestic)
                && (Words.abroad.matches(all) || foreignTrip || (flight && !homePlace))

            self.title = title
            self.location = location
            self.notes = notes
            self.all = all
            self.identity = identity
            self.isOnline = isOnline
            self.isMultiDay = isMultiDay
            isFlight = flight
            self.isAbroad = isAbroad
            isDomesticTrip = !isOnline && !pickup && !isAbroad && (flight || (homeTrip && !excluded(Words.notTravel)))
        }
    }

    /// The user's country, from the time zone: places there are not abroad.
    struct Home {
        let region: String?
        let inEurope: Bool

        init(timeZone: TimeZone) {
            let id = timeZone.identifier
            let region = NoteSuggester.region(forZone: id)
            self.region = region
            // "Europe" is abroad from the UK and Ireland, not from the continent.
            inEurope = id.hasPrefix("Europe/") && region != "GB" && region != "IE"
        }

        func contains(_ placeRegion: String) -> Bool {
            placeRegion == "EU" ? inEurope : placeRegion == region
        }
    }

    /// Every kind of event that matched, without those another one supersedes, best placed first.
    static func matchedCategories(in context: RuleContext) -> [Category] {
        var hits: [(category: Category, rank: Int, order: Int)] = []
        for (order, category) in categories.enumerated() {
            if let field = rank(of: category, in: context) { hits.append((category, field, order)) }
        }
        let superseded = Set(hits.flatMap { $0.category.supersedes })
        return hits
            .filter { !superseded.contains($0.category.id) }
            .sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }
            .map { $0.category }
    }

    /// nil when `category` does not match; else where it shows first: 0 title, 1 place, 2 notes, 3 only across them.
    private static func rank(of category: Category, in context: RuleContext) -> Int? {
        if category.inPersonOnly, context.isOnline { return nil }
        if let excludes = category.excludes, context.excludes(excludes, unlessSaidBy: category) { return nil }
        let hit: Bool
        switch category.special {
        case .abroad: hit = context.isAbroad
        case .domesticTravel: hit = category.matches(context.all) || context.isDomesticTrip
        case nil: hit = category.matches(context.all)
        }
        guard hit else { return nil }
        for (index, field) in context.fields.enumerated() where category.signals(in: field) { return index }
        return context.fields.count
    }

    /// `text` without words that start with "飛" but are no flight: "飛輪" (spin class), "飛盤", "飛鏢".
    static func withoutNotFlying(_ text: String) -> String {
        var result = text
        for word in ["飛輪", "飞轮", "飛盤", "飞盘", "飛鏢", "飞镖", "飛行傘", "飞行伞"] {
            result = result.replacingOccurrences(of: word, with: " ")
        }
        return result
    }

    static func region(forZone id: String) -> String? {
        if let region = zoneRegions[id] { return region }
        if id.hasPrefix("US/") || id.hasPrefix("America/Indiana/") || id.hasPrefix("America/Kentucky/")
            || id.hasPrefix("America/North_Dakota/") { return "US" }
        if id.hasPrefix("Australia/") { return "AU" }
        if id.hasPrefix("Canada/") { return "CA" }
        return nil
    }

    /// Every matcher in the tables, for the test that they all compile.
    static var allMatchers: [Matcher] {
        var matchers = [Words.flight, Words.fly, Words.abroad, Words.travelish, Words.trip, Words.headingTo,
                        Words.notTravel, Words.domestic, Words.planning,
                        Words.pickup,
                        Words.online, Words.onlineLinks, Words.business, Words.client, Words.roadTrip, Words.driving,
                        Words.birthday, Words.schoolTest, Words.languageExam, Words.idPhoto, foreignPlaces]
        matchers += places.map { $0.matcher }
        for category in categories {
            matchers.append(category.triggers)
            matchers += category.pairs.flatMap { [$0.0, $0.1] }
            matchers += [category.excludes].compactMap { $0 }
            for item in category.items { matchers += [item.onlyIf, item.unless].compactMap { $0 } }
        }
        return matchers
    }

    // MARK: Words

    enum Words {
        static let flight = Matcher(
            ["機場", "机场", "航班", "班機", "班机", "搭機", "搭机", "飛機", "飞机", "登機", "登机", "轉機", "转机",
             "國際線", "国际线", "航廈", "航站"],
            en: ["flights?", "airports?", "boarding", "layovers?", "(?:fly|flying) (?:to|out|back|home)"])
        /// A flight when a place is named too ("飛東京"): alone it is too common ("飛輪" is a spin class).
        static let fly = Matcher(["飛", "飞"], en: ["fly(?:ing)?", "flew"])
        static let abroad = Matcher(
            ["出國", "出国", "出境", "國外", "国外", "海外", "境外", "回國", "回国"],
            en: ["abroad", "overseas", "international (?:trips?|travel|flights?)"])
        /// With a foreign place: a trip there ("東京旅遊", "去日本", "Trip to Tokyo").
        static let travelish = Matcher(
            ["旅遊", "旅游", "旅行", "自由行", "跟團", "跟团", "度假", "渡假", "出差", "之旅", "遊", "游", "玩", "飛", "飞",
             "去", "赴", "行程", "出發", "出发"],
            en: ["trips?", "travel(?:s|ing|ling)?", "vacations?", "holidays?", "getaway", "honeymoon", "tours?",
                 "visit(?:s|ing)?", "conference", "backpacking", "cruise", "(?:going|go|heading|off|fly) to"])
        /// A foreign place that is not a trip: food, a language, a class, an embassy appointment.
        static let notTravel = Matcher(
            ["料理", "餐廳", "餐厅", "拉麵", "拉面", "壽司", "寿司", "燒肉", "烧肉", "菜", "語", "语", "課", "课", "電影", "电影",
             "超市", "大使館", "大使馆", "領事館", "领事馆", "辦事處", "办事处"],
            en: ["food", "restaurant", "cuisine", "ramen", "sushi", "bbq", "class(?:es)?", "lessons?", "language",
                 "embassy", "consulate"])
        static let domestic = Matcher(["國內", "国内"], en: ["domestic"])
        /// Clearly a trip, wherever it goes: with a place in the user's own country, a domestic trip.
        static let trip = Matcher(
            ["旅遊", "旅游", "旅行", "自由行", "跟團", "跟团", "度假", "渡假", "出差", "之旅", "出遊", "出游"],
            en: ["trips?", "travel(?:s|ing|ling)?", "vacations?", "getaway", "honeymoon", "backpacking", "cruise",
                 "weekend away"])
        /// Going somewhere: a trip when the title names a place in the user's country ("開車去台中", "Drive to Leeds").
        static let headingTo = Matcher(
            ["去", "赴", "前往", "出發", "出发", "飛", "飞"],
            en: ["(?:going|go|heading|off|fly|flying|drive|driving) to", "visit(?:s|ing)?"])
        /// Planning or booking a trip is not the trip.
        static let planning = Matcher(
            ["規劃", "规划", "訂機票", "订机票", "買機票", "买机票", "訂車票", "订车票", "訂飯店", "订酒店"],
            en: ["(?:trip|travel|vacation|holiday) planning", "plan(?:ning)? (?:the |a |our |my )?(?:trip|vacation|holiday)",
                 "book(?:ing)? (?:the |a |my |our )?(?:flights?|trains?|tickets?|hotels?)",
                 "flight (?:booking|deals?|prices?|search)"])
        /// Meeting someone at the airport or station, not travelling.
        static let pickup = Matcher(
            ["接機", "接机", "送機", "送机", "接人", "送人"],
            en: ["pick(?:ing)? (?:[a-z]+ )?up", "pick-?ups?", "drop(?:ping)? (?:[a-z]+ )?off", "drop-?offs?"])
        /// In the title or place: the event happens on a call.
        static let online = Matcher(
            ["線上", "线上", "視訊", "视讯", "视频会议", "遠端", "远端", "远程", "電話會議", "电话会议", "網路會議"],
            en: ["online", "virtual", "remote", "zoom", "google meet", "teams", "webex", "skype", "video ?calls?",
                 "conference calls?", "phone calls?", "calls?", "webinars?"])
        /// Anywhere: a video meeting link.
        static let onlineLinks = Matcher(["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com"])
        static let business = Matcher(
            ["出差", "拜訪", "拜访", "客戶", "客户", "研討會", "研讨会", "商展"],
            en: ["business trip", "clients?", "customers?", "conference", "trade show", "expo"])
        static let client = Matcher(
            ["客戶", "客户", "拜訪", "拜访", "廠商", "厂商"],
            en: ["clients?", "customers?", "vendors?", "suppliers?"])
        static let roadTrip = Matcher(
            ["自駕", "自驾", "租車", "租车", "長途", "长途", "環島", "环岛"],
            en: ["road ?trips?", "(?:car|van) (?:rental|hire)", "rent(?:ing)? a car", "rental car", "hire car", "long drive"])
        static let driving = Matcher(
            ["開車", "开车", "自駕", "自驾", "租車", "租车", "駕車", "驾车"],
            en: ["road ?trips?", "drive", "driving", "rental car", "(?:car|van) (?:rental|hire)"])
        static let birthday = Matcher(
            ["生日", "慶生", "庆生", "週年", "周年", "紀念日", "纪念日", "彌月", "弥月"],
            en: ["birthdays?", "b-?days?", "anniversary"])
        /// A class test: no admission ticket.
        static let schoolTest = Matcher(
            ["期中", "期末", "段考", "小考", "模擬考", "模拟考", "模考", "隨堂"],
            en: ["midterms?", "quiz(?:zes)?", "class tests?", "pop quiz"])
        /// No calculator.
        static let languageExam = Matcher(
            ["多益", "托福", "雅思", "英檢", "英检", "日檢", "日检", "韓檢", "英文", "英語", "英语", "日文", "日語", "日语", "國文",
             "语文"],
            en: ["toeic", "toefl", "ielts", "jlpt", "gept", "english", "language", "vocab(?:ulary)?", "spelling", "french",
                 "spanish", "german", "japanese", "chinese"])
        static let idPhoto = Matcher(
            ["護照", "护照", "簽證", "签证", "駕照", "驾照", "證件", "证件", "身分證", "身份证", "換證"],
            en: ["passports?", "visas?", "licen[cs]es?", "id cards?"])
    }

    // MARK: Places

    /// Places by country ("EU": Europe as a whole). Foreign unless in the user's country (`Home`).
    static let places: [(region: String, matcher: Matcher)] = [
        ("JP", Matcher(["日本", "東京", "东京", "大阪", "京都", "沖繩", "冲绳", "北海道", "札幌", "福岡", "福冈", "名古屋", "奈良",
                        "橫濱", "横滨", "箱根", "神戶", "神户"],
                       en: ["japan", "tokyo", "osaka", "kyoto", "okinawa", "hokkaido", "sapporo", "fukuoka", "nagoya", "nara",
                            "yokohama", "hakone", "kobe"])),
        ("KR", Matcher(["韓國", "韩国", "首爾", "首尔", "釜山", "濟州", "济州"], en: ["korea", "seoul", "busan", "jeju"])),
        ("TH", Matcher(["泰國", "泰国", "曼谷", "清邁", "清迈", "普吉"], en: ["thailand", "bangkok", "chiang mai", "phuket"])),
        ("VN", Matcher(["越南", "河內", "河内", "胡志明", "峴港", "岘港"], en: ["vietnam", "hanoi", "ho chi minh", "saigon", "da ?nang"])),
        ("SG", Matcher(["新加坡"], en: ["singapore"])),
        ("MY", Matcher(["馬來西亞", "马来西亚", "吉隆坡", "檳城", "槟城"], en: ["malaysia", "kuala lumpur", "penang"])),
        ("ID", Matcher(["印尼", "峇里島", "巴厘岛", "雅加達", "雅加达"], en: ["indonesia", "bali", "jakarta"])),
        ("PH", Matcher(["菲律賓", "菲律宾", "宿霧", "宿务", "長灘島", "长滩岛", "馬尼拉", "马尼拉"], en: ["philippines", "cebu", "boracay", "manila"])),
        ("HK", Matcher(["香港"], en: ["hong ?kong"])),
        ("MO", Matcher(["澳門", "澳门"], en: ["maca[ou]"])),
        ("CN", Matcher(["上海", "北京", "廣州", "广州", "深圳", "廈門", "厦门", "成都", "杭州", "中國大陸"],
                       en: ["shanghai", "beijing", "guangzhou", "shenzhen", "xiamen", "chengdu", "hangzhou"])),
        ("TW", Matcher(["台灣", "臺灣", "台北", "臺北", "高雄", "台中", "臺中", "台南", "臺南", "花蓮", "台東", "臺東", "澎湖", "金門",
                        "馬祖", "綠島", "蘭嶼", "小琉球", "墾丁", "宜蘭", "新竹", "嘉義", "屏東", "南投", "日月潭", "阿里山", "九份"],
                       en: ["taiwan", "taipei", "kaohsiung", "taichung", "tainan", "hualien", "taitung", "penghu", "kinmen"])),
        ("US", Matcher(["美國", "美国", "紐約", "纽约", "洛杉磯", "洛杉矶", "舊金山", "旧金山", "西雅圖", "西雅图", "夏威夷", "拉斯維加斯",
                        "拉斯维加斯", "波士頓", "波士顿", "芝加哥", "關島", "关岛"],
                       en: ["usa", "united states", "america", "new york", "nyc", "los angeles", "san francisco", "seattle",
                            "hawaii", "las vegas", "boston", "chicago", "guam"])),
        ("CA", Matcher(["加拿大", "溫哥華", "温哥华", "多倫多", "多伦多"], en: ["canada", "vancouver", "toronto", "montreal"])),
        ("MX", Matcher(["墨西哥", "坎昆"], en: ["mexico", "cancun"])),
        ("GB", Matcher(["英國", "英国", "倫敦", "伦敦", "蘇格蘭", "苏格兰", "愛丁堡", "爱丁堡"],
                       en: ["uk", "united kingdom", "england", "london", "scotland", "edinburgh", "manchester"])),
        ("IE", Matcher(["愛爾蘭", "爱尔兰"], en: ["ireland", "dublin"])),
        ("FR", Matcher(["法國", "法国", "巴黎"], en: ["france", "paris"])),
        ("DE", Matcher(["德國", "德国", "柏林", "慕尼黑"], en: ["germany", "berlin", "munich"])),
        ("IT", Matcher(["義大利", "意大利", "羅馬", "罗马", "米蘭", "米兰", "威尼斯", "佛羅倫斯", "佛罗伦萨"],
                       en: ["italy", "rome", "milan", "venice", "florence"])),
        ("ES", Matcher(["西班牙", "巴塞隆納", "巴塞罗那", "馬德里", "马德里"], en: ["spain", "madrid", "barcelona"])),
        ("PT", Matcher(["葡萄牙", "里斯本"], en: ["portugal", "lisbon"])),
        ("CH", Matcher(["瑞士", "蘇黎世", "苏黎世"], en: ["switzerland", "zurich", "geneva"])),
        ("NL", Matcher(["荷蘭", "荷兰", "阿姆斯特丹"], en: ["netherlands", "holland", "amsterdam"])),
        ("AT", Matcher(["奧地利", "奥地利", "維也納", "维也纳"], en: ["austria", "vienna"])),
        ("CZ", Matcher(["捷克", "布拉格"], en: ["czechia", "czech republic", "prague"])),
        ("GR", Matcher(["希臘", "希腊", "雅典"], en: ["greece", "athens", "santorini"])),
        ("TR", Matcher(["土耳其", "伊斯坦堡", "伊斯坦布尔"], en: ["turkiye", "istanbul"])),
        ("EU", Matcher(["歐洲", "欧洲"], en: ["europe"])),
        ("AE", Matcher(["杜拜", "迪拜", "阿布達比"], en: ["dubai", "abu dhabi"])),
        ("AU", Matcher(["澳洲", "澳大利亚", "雪梨", "悉尼", "墨爾本", "墨尔本", "布里斯本"], en: ["australia", "sydney", "melbourne", "brisbane"])),
        ("NZ", Matcher(["紐西蘭", "新西兰", "奧克蘭", "奥克兰"], en: ["new zealand", "auckland"])),
        ("IS", Matcher(["冰島", "冰岛"], en: ["iceland"])),
        ("EG", Matcher(["埃及"], en: ["egypt"])),
        ("IN", Matcher(["印度"], en: ["india"])),
        ("MV", Matcher(["馬爾地夫", "马尔代夫"], en: ["maldives"])),
        ("PW", Matcher(["帛琉"], en: ["palau"]))
    ]

    /// Every place, wherever the user lives: for ranking only (`Category.signals`).
    static let foreignPlaces = Matcher(places.flatMap { $0.matcher.phrases }, en: places.flatMap { $0.matcher.patterns })

    static let zoneRegions: [String: String] = [
        "Asia/Taipei": "TW", "Asia/Tokyo": "JP", "Asia/Seoul": "KR", "Asia/Bangkok": "TH", "Asia/Ho_Chi_Minh": "VN",
        "Asia/Saigon": "VN", "Asia/Singapore": "SG", "Asia/Kuala_Lumpur": "MY", "Asia/Jakarta": "ID",
        "Asia/Makassar": "ID", "Asia/Manila": "PH", "Asia/Hong_Kong": "HK", "Asia/Macau": "MO", "Asia/Shanghai": "CN",
        "Asia/Chongqing": "CN", "Asia/Urumqi": "CN", "Asia/Dubai": "AE", "Asia/Kolkata": "IN", "Asia/Calcutta": "IN",
        "Indian/Maldives": "MV", "Pacific/Palau": "PW",
        "Europe/London": "GB", "Europe/Dublin": "IE", "Europe/Paris": "FR", "Europe/Berlin": "DE", "Europe/Rome": "IT",
        "Europe/Madrid": "ES", "Europe/Lisbon": "PT", "Europe/Zurich": "CH", "Europe/Amsterdam": "NL",
        "Europe/Vienna": "AT", "Europe/Prague": "CZ", "Europe/Athens": "GR", "Europe/Istanbul": "TR",
        "Atlantic/Reykjavik": "IS", "Africa/Cairo": "EG", "Pacific/Auckland": "NZ",
        "America/New_York": "US", "America/Chicago": "US", "America/Denver": "US", "America/Los_Angeles": "US",
        "America/Phoenix": "US", "America/Anchorage": "US", "America/Detroit": "US", "America/Boise": "US",
        "Pacific/Honolulu": "US", "Pacific/Guam": "US",
        "America/Toronto": "CA", "America/Vancouver": "CA", "America/Edmonton": "CA", "America/Winnipeg": "CA",
        "America/Halifax": "CA", "America/St_Johns": "CA", "America/Regina": "CA", "America/Montreal": "CA",
        "America/Mexico_City": "MX", "America/Cancun": "MX", "America/Tijuana": "MX"
    ]

    // MARK: Items

    enum Items {
        // Travel
        static let passport = Item(id: "passport", en: "Bring passport", zh: "帶護照", keys: ["passport", "護照", "护照"])
        static let flightEarly = Item(id: "flight-early", en: "Arrive 2-3 hours before the flight", zh: "提早 2-3 小時到機場",
                                      keys: ["hours before the flight", "提早到機場", "提早到机场", "提前到机场"], flight: true)
        static let visa = Item(id: "visa", en: "Check visa or entry documents", zh: "確認簽證或入境文件",
                               keys: ["visa", "entry documents", "簽證", "签证", "入境"])
        static let adapter = Item(id: "adapter", en: "Pack a plug adapter", zh: "帶轉接插頭",
                                  keys: ["plug adapter", "travel adapter", "轉接插頭", "转换插头", "萬國插頭"])
        static let travelInsurance = Item(id: "travel-insurance", en: "Get travel insurance", zh: "投保旅遊保險",
                                          keys: ["travel insurance", "旅遊保險", "旅平險", "旅游保险", "不便險"])
        static let powerBank = Item(id: "power-bank", en: "Bring a power bank", zh: "帶行動電源",
                                    keys: ["power bank", "portable charger", "行動電源", "充電寶", "充电宝"])
        static let id = Item(id: "id", en: "Bring ID", zh: "帶身分證", keys: ["id", "id card", "identity card", "身分證", "身份證", "身份证"])
        static let tickets = Item(id: "tickets", en: "Have tickets ready", zh: "準備好車票", keys: ["tickets", "ticket", "車票", "车票", "票券"],
                                  unless: Words.driving, flight: false)
        static let checkIn = Item(id: "check-in", en: "Check in online", zh: "完成線上報到",
                                  keys: ["check in", "check-in", "checked in", "線上報到", "网上值机", "值機", "值机", "報到"], flight: true)
        static let businessCards = Item(id: "business-cards", en: "Bring business cards", zh: "帶名片",
                                        keys: ["business cards", "名片"], onlyIf: Words.business)

        // Sport
        static let water = Item(id: "water", en: "Bring water", zh: "帶水",
                                keys: ["water", "水壺", "水壶", "水瓶", "飲用水", "饮用水"])
        static let towel = Item(id: "towel", en: "Bring a towel", zh: "帶毛巾", keys: ["towel", "毛巾"])
        static let sportswear = Item(id: "sportswear", en: "Sportswear and shoes", zh: "穿運動服和運動鞋",
                                     keys: ["sportswear", "trainers", "sneakers", "running shoes", "運動服", "运动服", "運動鞋", "运动鞋"])
        static let changeOfClothes = Item(id: "change-of-clothes", en: "Change of clothes", zh: "帶替換衣物",
                                          keys: ["change of clothes", "spare clothes", "替換衣物", "換洗衣物", "换洗衣物"])
        static let yogaMat = Item(id: "yoga-mat", en: "Bring a yoga mat", zh: "帶瑜伽墊", keys: ["yoga mat", "mat", "瑜伽墊", "瑜珈墊", "瑜伽垫"])
        static let comfortableClothes = Item(id: "comfortable-clothes", en: "Comfortable clothes", zh: "穿舒適的衣服",
                                             keys: ["comfortable clothes", "舒適的衣服", "舒适的衣服", "舒適衣物"])
        static let swimsuit = Item(id: "swimsuit", en: "Bring a swimsuit", zh: "帶泳衣",
                                   keys: ["swimsuit", "swimwear", "swimming costume", "trunks", "泳衣", "泳褲", "泳裤"])
        static let goggles = Item(id: "goggles", en: "Bring goggles", zh: "帶泳鏡", keys: ["goggles", "泳鏡", "泳镜", "蛙鏡"])
        static let swimCap = Item(id: "swim-cap", en: "Bring a swim cap", zh: "帶泳帽", keys: ["swim cap", "泳帽"])

        // Outdoors
        static let rainGear = Item(id: "rain-gear", en: "Bring rain gear", zh: "帶雨具",
                                   keys: ["rain gear", "raincoat", "rain jacket", "umbrella", "雨具", "雨衣", "雨傘", "雨伞"])
        static let snacks = Item(id: "snacks", en: "Pack snacks", zh: "帶行動糧",
                                 keys: ["snacks", "trail food", "行動糧", "行动粮", "零食", "乾糧", "干粮"])
        static let headlamp = Item(id: "headlamp", en: "Bring a headlamp", zh: "帶頭燈",
                                   keys: ["headlamp", "head torch", "flashlight", "torch", "頭燈", "头灯", "手電筒"])
        static let weather = Item(id: "weather", en: "Check the weather", zh: "查看天氣預報", keys: ["weather", "forecast", "天氣", "天气"])
        static let tentAndSleepingBag = Item(id: "tent", en: "Tent and sleeping bag", zh: "帶帳篷和睡袋",
                                             keys: ["tent", "sleeping bag", "帳篷", "帐篷", "睡袋"])
        static let insectRepellent = Item(id: "insect-repellent", en: "Insect repellent", zh: "帶防蚊液",
                                          keys: ["insect repellent", "bug spray", "mosquito", "防蚊", "驅蚊", "驱蚊"])
        static let sunscreen = Item(id: "sunscreen", en: "Bring sunscreen", zh: "帶防曬乳", keys: ["sunscreen", "sunblock", "spf", "防曬", "防晒"])
        static let hat = Item(id: "hat", en: "Bring a hat", zh: "帶帽子", keys: ["hat", "sun hat", "帽子", "遮陽帽"])

        // Work
        static let cv = Item(id: "cv", en: "Bring your CV", zh: "帶履歷", keys: ["cv", "resume", "履歷", "履历", "簡歷", "简历"], online: false)
        static let tenMinutesEarly = Item(id: "ten-minutes-early", en: "Arrive 10 min early", zh: "提早 10 分鐘到",
                                          keys: ["arrive early", "10 min early", "提早 10 分鐘", "提前 10 分钟"], online: false)
        static let questions = Item(id: "questions", en: "Prepare questions to ask", zh: "準備想問的問題", keys: ["questions", "問題", "问题"])
        static let micAndCamera = Item(id: "mic-camera", en: "Test mic and camera", zh: "測試麥克風和鏡頭",
                                       keys: ["mic", "microphone", "camera", "麥克風", "麦克风", "鏡頭", "镜头"], online: true)
        static let meetingLink = Item(id: "meeting-link", en: "Check the meeting link", zh: "確認會議連結",
                                      keys: ["meeting link", "link", "連結", "链接"], online: true)
        static let laptop = Item(id: "laptop", en: "Laptop and charger", zh: "帶筆電和充電器",
                                 keys: ["laptop", "notebook", "charger", "筆電", "笔电", "筆記型電腦", "充電器", "充电器"], online: false)
        static let slidesBackup = Item(id: "slides-backup", en: "Back up the slides", zh: "備份簡報檔",
                                       keys: ["backup", "back up", "usb", "備份", "备份", "隨身碟", "u盘"])
        static let displayAdapter = Item(id: "display-adapter", en: "Display adapter (HDMI)", zh: "帶投影轉接頭",
                                         keys: ["hdmi", "display adapter", "dongle", "投影轉接", "投影转接"], online: false)
        static let clientCards = Item(id: "business-cards", en: "Bring business cards", zh: "帶名片",
                                      keys: ["business cards", "名片"], onlyIf: Words.client, online: false)

        // Health, exams, errands
        static let insuranceCard = Item(id: "insurance-card", en: "Bring health insurance card", zh: "帶健保卡",
                                        keys: ["insurance card", "health card", "健保卡", "醫保卡", "医保卡"])
        static let medicineList = Item(id: "medicine-list", en: "List of current medicines", zh: "帶目前用藥清單",
                                       keys: ["medicines", "medication", "medications", "用藥", "用药", "藥單", "药单", "藥袋"])
        static let doctorQuestions = Item(id: "doctor-questions", en: "Write down questions for the doctor", zh: "寫下想問醫生的問題",
                                          keys: ["questions", "問題", "问题"])
        static let admissionTicket = Item(id: "admission-ticket", en: "Bring admission ticket", zh: "帶准考證",
                                          keys: ["admission ticket", "admission", "准考證", "准考证"], unless: Words.schoolTest)
        static let stationery = Item(id: "stationery", en: "Bring stationery", zh: "帶文具",
                                     keys: ["stationery", "pencil", "pencils", "pens", "文具", "鉛筆", "铅笔", "原子筆", "2b"])
        static let calculator = Item(id: "calculator", en: "Bring a calculator", zh: "帶計算機",
                                     keys: ["calculator", "計算機", "计算器"], unless: Words.languageExam)
        static let documents = Item(id: "documents", en: "Bring required documents", zh: "帶齊所需文件",
                                    keys: ["documents", "paperwork", "文件", "資料", "资料"])
        static let idPhotos = Item(id: "id-photos", en: "Bring ID photos", zh: "帶證件照",
                                   keys: ["photo", "photos", "證件照", "证件照", "大頭照"], onlyIf: Words.idPhoto)

        // Occasions
        static let gift = Item(id: "gift", en: "Get a gift", zh: "準備禮物", keys: ["gift", "present", "禮物", "礼物"])
        static let card = Item(id: "card", en: "Write a card", zh: "寫張卡片", keys: ["birthday card", "greeting card", "卡片"],
                               onlyIf: Words.birthday)
        static let weddingGift = Item(id: "wedding-gift", en: "Wedding gift or card", zh: "準備紅包",
                                      keys: ["wedding gift", "red envelope", "紅包", "红包", "禮金", "礼金"])
        static let dressCode = Item(id: "dress-code", en: "Check the dress code", zh: "確認服裝規定", keys: ["dress code", "服裝", "服装"])
        static let eventTicket = Item(id: "event-ticket", en: "Have your ticket ready", zh: "準備好門票",
                                      keys: ["ticket", "tickets", "門票", "门票", "票券", "電子票"])
        static let reservation = Item(id: "reservation", en: "Confirm the reservation", zh: "確認訂位",
                                      keys: ["reservation", "booking", "訂位", "订位", "預約", "预约"])

        // Driving
        static let internationalPermit = Item(id: "international-permit", en: "International driving permit", zh: "帶國際駕照",
                                              keys: ["international driving permit", "idp", "國際駕照", "国际驾照"], requires: "abroad")
        static let licence = Item(id: "licence", en: "Bring driving licence", zh: "帶駕照", keys: ["licence", "license", "駕照", "驾照"])
        static let routeAndParking = Item(id: "route-parking", en: "Plan route and parking", zh: "查好路線和停車",
                                          keys: ["route", "parking", "路線", "路线", "停車", "停车"])
        static let fuel = Item(id: "fuel", en: "Check fuel or charge", zh: "確認油量或電量",
                               keys: ["fuel", "petrol", "油量", "加油", "電量", "电量"], onlyIf: Words.roadTrip)
    }

    // MARK: Kinds of event

    /// In priority order: when two kinds show in the same field, the earlier one leads.
    static let categories: [Category] = [
        Category(id: "abroad",
                 triggers: .any(Words.abroad, Words.flight),
                 pairs: [(Words.travelish, foreignPlaces)],
                 excludes: .any(Words.pickup, Words.domestic, Words.planning,
                                Matcher(["機場捷運", "机场捷运", "機捷", "飛機模型", "飞机模型"],
                                        en: ["airport runs?", "model (?:planes?|aircraft)"])),
                 supersedes: ["travel"],
                 inPersonOnly: true,
                 special: .abroad,
                 items: [Items.passport, Items.flightEarly, Items.visa, Items.adapter, Items.travelInsurance, Items.checkIn,
                         Items.powerBank]),
        Category(id: "interview",
                 triggers: Matcher(["面試", "面试", "口試", "口试"], en: ["(?:job )?interviews?"]),
                 excludes: Matcher(en: ["podcast", "user interviews?"]),
                 supersedes: ["meeting"],
                 items: [Items.cv, Items.tenMinutesEarly, Items.micAndCamera, Items.questions]),
        Category(id: "presentation",
                 triggers: Matcher(["簡報", "简报", "提案", "發表", "发表", "演講", "演讲", "分享會", "分享会", "報告", "报告"],
                                   en: ["presentations?", "presenting", "pitch(?:ing)?", "keynote", "demo day", "speech"]),
                 excludes: Matcher(["看報告", "看报告", "報告出爐", "健檢報告", "體檢報告", "体检报告", "檢查報告", "检查报告", "交報告",
                                    "交报告", "寫報告", "写报告"],
                                   en: ["football pitch", "speech therapy"]),
                 supersedes: ["meeting"],
                 items: [Items.laptop, Items.slidesBackup, Items.displayAdapter, Items.tenMinutesEarly, Items.micAndCamera]),
        Category(id: "exam",
                 triggers: Matcher(["考試", "考试", "期中考", "期末考", "段考", "小考", "模擬考", "模拟考", "模考", "會考", "会考", "學測",
                                    "学测", "指考", "分科測驗", "統測", "统测", "國考", "国考", "高考", "考研", "檢定", "检定", "多益",
                                    "托福", "雅思", "英檢", "英检", "日檢", "日检", "筆試", "笔试", "術科", "證照考", "证照考"],
                                   en: ["exams?", "examinations?", "midterms?", "final exams?", "finals week", "quiz(?:zes)?", "tests?",
                                        "toeic", "toefl", "ielts", "gre", "gmat", "jlpt", "gept", "bar exam"]),
                 excludes: Matcher(["驗血", "验血", "抽血", "快篩", "快筛", "篩檢", "筛检", "健康檢查", "健康检查", "視力檢查", "试驾", "試駕"],
                                   en: ["(?:blood|covid|pcr|antigen|eye|hearing|drug|urine|pregnancy|lateral flow|a/?b|ab|unit|load|user|usability|penetration|pen|smoke|beta|stress|integration|ui|qa|regression|performance|speed) tests?",
                                        "test (?:drive|run|flight|results?|event|meeting|call|environment|build|server)",
                                        "test (?:the|a|an|our|my|this|that|new) [a-z]+",
                                        "(?:eye|medical|dental|physical) exams?"]),
                 items: [Items.admissionTicket, Items.id, Items.stationery, Items.calculator]),
        Category(id: "doctor",
                 triggers: Matcher(["看醫生", "看医生", "看診", "看诊", "門診", "门诊", "回診", "回诊", "複診", "复诊", "掛號", "挂号", "牙醫",
                                    "牙医", "看牙", "洗牙", "拔牙", "補牙", "补牙", "醫院", "医院", "診所", "诊所", "健檢", "體檢", "体检",
                                    "健康檢查", "健康检查", "打疫苗", "疫苗", "復健", "复健", "中醫", "中医", "針灸", "针灸", "眼科", "皮膚科",
                                    "皮肤科", "耳鼻喉", "小兒科", "儿科", "婦產科", "妇产科", "骨科", "家醫科", "身心科", "精神科", "產檢",
                                    "产检", "抽血", "驗血", "验血", "胃鏡", "胃镜", "大腸鏡", "肠镜", "看病", "就醫", "就医"],
                                   en: ["doctors?", #"dr\.?"#, "gp", "dentist", "dental", "orthodontist", "clinic", "hospital",
                                        "check-?ups?", "physio(?:therapy)?", "vaccin(?:e|es|ation)", "flu shot", "booster", "blood test",
                                        "optometrist", "eye (?:exam|test|appointment)", "medical", "dermatologist", "p(?:a)?ediatrician",
                                        "ob-?gyn", "x-?ray", "mri", "ultrasound", "speech therapy"]),
                 excludes: Matcher(["探病", "探望", "探視", "探视", "動物醫院", "动物医院", "獸醫", "兽医", "寵物", "宠物"],
                                   en: ["doctor who", "vets?", "veterinar(?:y|ian)", "pets?", "visiting hours",
                                        "visit(?:ing)? (?:[a-z']+ ){0,3}(?:at|in) (?:the )?hospital"]),
                 items: [Items.insuranceCard, Items.medicineList, Items.doctorQuestions]),
        Category(id: "wedding",
                 triggers: Matcher(["婚禮", "婚礼", "喜宴", "喜酒", "訂婚", "订婚", "結婚", "结婚", "歸寧", "归宁", "文定"],
                                   en: ["weddings?", "engagement party", "wedding reception"]),
                 excludes: Matcher(["登記", "登记", "週年", "周年", "紀念日", "纪念日"], en: ["anniversary"]),
                 supersedes: ["party"],
                 items: [Items.weddingGift, Items.dressCode]),
        Category(id: "party",
                 triggers: Matcher(["生日", "慶生", "庆生", "派對", "派对", "聚會", "聚会", "喬遷", "乔迁", "彌月", "弥月", "週年", "周年",
                                    "紀念日", "纪念日", "交換禮物", "交换礼物"],
                                   en: ["birthdays?", "b-?days?", "part(?:y|ies)", "celebrations?", "housewarming", "baby shower",
                                        "bridal shower", "anniversary", "gift exchange"]),
                 excludes: Matcher(["政黨", "政党", "週年慶", "周年庆"],
                                   en: ["third[- ]part(?:y|ies)", "3rd[- ]part(?:y|ies)", "party (?:line|leader|congress|conference|members?)",
                                        "(?:company|work) anniversary"]),
                 items: [Items.gift, Items.card]),
        Category(id: "concert",
                 triggers: Matcher(["演唱會", "演唱会", "音樂會", "音乐会", "音樂祭", "音樂節", "音乐节", "看展", "展覽", "展览", "展演", "看表演",
                                    "看戲", "看戏", "舞台劇", "舞台剧", "音樂劇", "音乐剧", "歌劇", "歌剧", "芭蕾", "球賽", "球赛", "看球",
                                    "博物館", "博物馆", "美術館", "美术馆", "劇場", "剧场", "脫口秀", "脱口秀"],
                                   en: ["concerts?", "gigs?", "(?:music|film|arts?|jazz) festivals?", "exhibitions?", "expo", "museums?",
                                        "galler(?:y|ies)", "musicals?", "theat(?:re|er)", "opera", "ballet", "live show", "comedy show",
                                        "stand-?up comedy"]),
                 excludes: Matcher(["佈展", "布展", "撤展"], en: ["operating theat(?:re|er)"]),
                 items: [Items.eventTicket, Items.id, Items.powerBank]),
        Category(id: "swimming",
                 triggers: Matcher(["游泳", "泳池", "泳訓", "泳训", "泳課", "泳课", "泳隊", "泳队"],
                                   en: ["swim(?:s|ming)?", "swimming pool", "aqua ?(?:fit|aerobics)", "lane swim"]),
                 excludes: Matcher(["清潔", "清洁", "維修", "维修", "保養", "保养"],
                                   en: ["swim ?lanes?", "pool (?:cleaning|maintenance|repairs?)"]),
                 supersedes: ["workout"],
                 items: [Items.swimsuit, Items.goggles, Items.towel, Items.swimCap]),
        Category(id: "yoga",
                 triggers: Matcher(["瑜伽", "瑜珈", "皮拉提斯", "彼拉提斯"], en: ["yoga", "pilates"]),
                 supersedes: ["workout"],
                 items: [Items.yogaMat, Items.water, Items.comfortableClothes, Items.towel]),
        Category(id: "hiking",
                 triggers: Matcher(["登山", "爬山", "健行", "步道", "郊山", "百岳", "攀登", "徒步", "縱走", "纵走", "山屋", "溯溪"],
                                   en: ["hik(?:e|es|ing)", "trek(?:s|king)?", "hill ?walk(?:s|ing)?", "mountain (?:walks?|hikes?|trips?)",
                                        "fell walk(?:s|ing)?"]),
                 excludes: Matcher(["登山用品"], en: ["star trek", "(?:price|rate|tax) hikes?"]),
                 supersedes: ["workout"],
                 items: [Items.water, Items.rainGear, Items.snacks, Items.headlamp, Items.weather]),
        Category(id: "camping",
                 triggers: Matcher(["露營", "露营", "營地", "营地", "野營", "野营"], en: ["camping", "campsites?", "campgrounds?", "glamping"]),
                 items: [Items.tentAndSleepingBag, Items.headlamp, Items.insectRepellent, Items.rainGear]),
        Category(id: "beach",
                 triggers: Matcher(["海邊", "海边", "海灘", "海滩", "沙灘", "沙滩", "浮潛", "浮潜", "衝浪", "冲浪", "玩水", "潛水", "潜水"],
                                   en: ["beach(?:es)?", "snorkel(?:l)?ing", "surfing", "seaside", "scuba"]),
                 items: [Items.sunscreen, Items.swimsuit, Items.towel, Items.hat]),
        Category(id: "workout",
                 triggers: Matcher(["健身", "重訓", "重训", "跑步", "慢跑", "夜跑", "晨跑", "路跑", "馬拉松", "马拉松", "運動", "运动", "有氧",
                                    "飛輪", "飞轮", "拳擊", "拳击", "踢拳", "格鬥", "格斗", "籃球", "篮球", "羽球", "羽毛球", "網球", "网球",
                                    "桌球", "乒乓", "排球", "足球", "壁球", "匹克球", "單車", "单车", "自行車", "自行车", "腳踏車", "脚踏车",
                                    "練腿", "练腿", "練胸", "练胸", "練背", "练背", "練肩", "核心訓練", "肌力訓練", "體能訓練", "体能训练",
                                    "重量訓練", "健走", "打球", "練球", "攀岩", "抱石", "划船"],
                                   en: ["gym", "work ?outs?", "working out", "exercis(?:e|es|ing)", "fitness", "cross ?fit", "hiit",
                                        "cardio", "spin(?:ning)? class(?:es)?", "cycling", "bike ride", "basketball", "tennis",
                                        "badminton", "table tennis", "ping ?pong", "volleyball", "soccer", "football (?:practice|training)",
                                        "squash", "boxing", "kickboxing", "(?:half )?marathons?", #"\d+ ?k(?:m)? runs?"#,
                                        #"runs? \d+(?:\.\d+)? ?(?:km?|mi(?:les?)?)"#, "running",
                                        "jog(?:s|ging)?", "run club",
                                        "(?:morning|evening|easy|long|tempo|trail|recovery|interval|park|group|lunch) runs?",
                                        "go(?:ing)? for a run", "(?:leg|arm|chest|back|push|pull|shoulder) day", "weightlifting",
                                        "lifting", "(?:weight|strength|circuit|interval|personal) training", "pt session", "rowing",
                                        "climbing", "bouldering", "martial arts", "karate", "judo", "taekwondo", "muay thai",
                                        "jiu ?jitsu", "pickleball"]),
                 // A repair, a purchase or a match on TV is no workout ("跑步機維修"); renewing a gym membership still is.
                 excludes: Matcher(["維修", "维修", "修理", "保養", "保养", "送修", "購買", "购买", "選購", "选购", "買", "买", "退貨", "退货",
                                    "傷害", "伤害", "彩券", "轉播", "转播", "看球", "球賽", "球赛", "購物", "购物", "用品店"],
                                   en: ["repairs?", "fix(?:ing)?", "maintenance", "servicing", "buy(?:ing)?", "purchase", "returns?",
                                        "refund", "cancel(?:l?ing|l?ations?)?", "injury", "shop(?:ping)?", "store", "deliver(?:y|ed|ies)", "running (?:late|behind|out|the|a|an|for|over)",
                                        "(?:fire|tabletop|evacuation) (?:drills?|exercises?)", "watch(?:ing)?", "doctor who",
                                        "(?:movie|film|tv|netflix|series|binge) marathons?"]),
                 items: [Items.water, Items.towel, Items.sportswear, Items.changeOfClothes]),
        Category(id: "driving",
                 triggers: Matcher(["開車", "开车", "自駕", "自驾", "租車", "租车", "駕車", "驾车", "路考", "駕訓", "驾训"],
                                   en: ["road ?trips?", "(?:car|van) (?:rental|hire)", "rent(?:ing)? a car", "rental car", "hire car",
                                        "driving (?:to|lessons?|tests?)", "drive (?:to|home|back|up|down)", "test drive"]),
                 excludes: Matcher(en: ["google drive", "hard drive", "drive-?thru", "(?:usb|flash|shared|team|network) drive"]),
                 inPersonOnly: true,
                 items: [Items.internationalPermit, Items.licence, Items.routeAndParking, Items.fuel]),
        Category(id: "travel",
                 triggers: Matcher(["高鐵", "高铁", "台鐵", "臺鐵", "火車", "火车", "動車", "动车", "客運", "客运", "國內旅遊", "国内旅游",
                                    "環島", "环岛", "小旅行", "旅遊", "旅游", "旅行", "出遊", "出游", "度假", "渡假", "出差", "自由行", "跟團",
                                    "跟团", "返鄉", "返乡", "回老家", "車票", "车票", "國內線", "国内航班"],
                                   en: ["trains?", "rail", "high-speed rail", "thsr", "amtrak", "trips?", "travel(?:s|ing|ling)?",
                                        "vacations?", "getaway", "weekend away", "business trip", "domestic flights?"]),
                 excludes: .any(Words.pickup, Words.planning,
                                Matcher(["旅行社"], en: ["travel (?:expenses?|reimbursements?|claims?|policy|budget|agency)"])),
                 inPersonOnly: true,
                 special: .domesticTravel,
                 items: [Items.id, Items.tickets, Items.checkIn, Items.powerBank, Items.businessCards]),
        Category(id: "errands",
                 triggers: Matcher(["銀行", "银行", "郵局", "邮局", "戶政", "户政", "區公所", "区公所", "監理站", "監理所", "监理所", "國稅局",
                                    "国税局", "稅務局", "税务局", "辦護照", "办护照", "換護照", "换护照", "換駕照", "换驾照", "換證", "换证",
                                    "辦證", "办证", "開戶", "开户", "辦簽證", "办签证", "公證", "公证", "地政", "健保署", "勞保局", "劳保局",
                                    "移民署", "大使館", "大使馆", "領事館", "领事馆", "領務局"],
                                   en: ["bank appointment", "open(?:ing)? an? (?:bank )?account", "dmv", "post office", "city hall",
                                        "embassy", "consulate", "visa appointment", "passport (?:renewal|appointment|application|office)",
                                        "renew(?:ing)? (?:my |the |your )?(?:passport|licen[cs]e|id)", "notary"]),
                 items: [Items.id, Items.documents, Items.idPhotos]),
        Category(id: "meeting",
                 triggers: Matcher(["會議", "会议", "開會", "开会", "會面", "会面", "拜訪", "拜访", "洽談", "洽谈", "研討會", "研讨会", "工作坊",
                                    "討論", "讨论", "一對一", "一对一", "晤談", "面談", "面谈"],
                                   en: ["meetings?", "meet(?:ing)? with", "1:1", "1-on-1", "one-on-one", "client visit", "workshops?",
                                        "conference", "seminars?", "kick-?off", "offsite"]),
                 items: [Items.laptop, Items.tenMinutesEarly, Items.micAndCamera, Items.meetingLink, Items.clientCards]),
        Category(id: "reservation",
                 triggers: Matcher(["訂位", "订位", "餐廳", "餐厅", "約會", "约会", "聚餐", "燭光晚餐", "烛光晚餐", "晚宴", "包廂", "包厢"],
                                   en: ["reservations?", "booking at", "restaurant", "date night", "dinner date", #"table for \d+"#]),
                 items: [Items.reservation])
    ]
}
