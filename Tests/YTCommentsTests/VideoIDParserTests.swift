import Testing
@testable import YTComments

@Suite("VideoIDParser")
struct VideoIDParserTests {
    let id = "dQw4w9WgXcQ"

    @Test func watchURL() {
        #expect(VideoIDParser.extract(from: "https://www.youtube.com/watch?v=\(id)") == id)
    }

    @Test func watchURLWithExtraParams() {
        #expect(VideoIDParser.extract(from: "https://www.youtube.com/watch?v=\(id)&t=42s&list=PLxyz") == id)
    }

    @Test func shortURL() {
        #expect(VideoIDParser.extract(from: "https://youtu.be/\(id)") == id)
    }

    @Test func shortURLWithTimestamp() {
        #expect(VideoIDParser.extract(from: "https://youtu.be/\(id)?t=10") == id)
    }

    @Test func shortsURL() {
        #expect(VideoIDParser.extract(from: "https://www.youtube.com/shorts/\(id)") == id)
    }

    @Test func embedURL() {
        #expect(VideoIDParser.extract(from: "https://www.youtube.com/embed/\(id)") == id)
    }

    @Test func liveURL() {
        #expect(VideoIDParser.extract(from: "https://www.youtube.com/live/\(id)") == id)
    }

    @Test func mobileURL() {
        #expect(VideoIDParser.extract(from: "https://m.youtube.com/watch?v=\(id)") == id)
    }

    @Test func noSchemeURL() {
        #expect(VideoIDParser.extract(from: "youtu.be/\(id)") == id)
    }

    @Test func bareID() {
        #expect(VideoIDParser.extract(from: id) == id)
    }

    @Test func whitespaceTrimmed() {
        #expect(VideoIDParser.extract(from: "  https://youtu.be/\(id)  ") == id)
    }

    @Test func invalidGarbage() {
        #expect(VideoIDParser.extract(from: "not a youtube link") == nil)
    }

    @Test func wrongLengthID() {
        #expect(VideoIDParser.extract(from: "shortid") == nil)
    }

    @Test func empty() {
        #expect(VideoIDParser.extract(from: "   ") == nil)
    }
}
