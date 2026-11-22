import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
@testable import Madrigal

struct MarkdownTests {
    typealias Block = MarkdownText.Block
    typealias Item = MarkdownText.ListItem

    @Test func headingsAndParagraphs() {
        let blocks = MarkdownText.blocks(of: "# Title\n\nSome **bold** text\nsecond line\n\n### Sub ###")
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Some **bold** text\nsecond line"),
            .heading(level: 3, text: "Sub")
        ])
    }

    @Test func hashtagIsNotAHeading() {
        #expect(MarkdownText.blocks(of: "#swift is fun") == [.paragraph("#swift is fun")])
    }

    @Test func nestedAndOrderedLists() {
        let text = """
        - one
          - nested
        - two

        1. first
        2) second
        """
        #expect(MarkdownText.blocks(of: text) == [
            .list([
                Item(marker: .bullet, depth: 0, text: "one"),
                Item(marker: .bullet, depth: 1, text: "nested"),
                Item(marker: .bullet, depth: 0, text: "two"),
                Item(marker: .ordered("1."), depth: 0, text: "first"),
                Item(marker: .ordered("2)"), depth: 0, text: "second")
            ])
        ])
    }

    @Test func listEndsAtParagraphAfterBlankLine() {
        let blocks = MarkdownText.blocks(of: "- a\n- b\n\nAfter.")
        #expect(blocks == [
            .list([Item(marker: .bullet, depth: 0, text: "a"), Item(marker: .bullet, depth: 0, text: "b")]),
            .paragraph("After.")
        ])
    }

    @Test func lazyContinuationJoinsItem() {
        #expect(MarkdownText.blocks(of: "- item\ncontinued") == [
            .list([Item(marker: .bullet, depth: 0, text: "item\ncontinued")])
        ])
    }

    @Test func taskItems() {
        #expect(MarkdownText.blocks(of: "- [ ] todo\n- [x] done") == [
            .list([
                Item(marker: .task(checked: false), depth: 0, text: "todo"),
                Item(marker: .task(checked: true), depth: 0, text: "done")
            ])
        ])
    }

    @Test func boldLineIsNotAListOrRule() {
        #expect(MarkdownText.blocks(of: "**Note:** careful") == [.paragraph("**Note:** careful")])
    }

    @Test func quotesAndRules() {
        let blocks = MarkdownText.blocks(of: "> quoted\n> more\n\n---\n\n* * *")
        #expect(blocks == [.quote("quoted\nmore"), .rule, .rule])
    }

    @Test func table() {
        let text = """
        | Name | Value |
        |:-----|------:|
        | a | 1 |
        | b |
        """
        #expect(MarkdownText.blocks(of: text) == [
            .table(header: ["Name", "Value"], rows: [["a", "1"], ["b", ""]])
        ])
    }

    @Test func fencedCode() {
        let text = "Before\n```swift\nlet x = 1\n\n# not a heading\n```\nAfter"
        #expect(MarkdownText.blocks(of: text) == [
            .paragraph("Before"),
            .code(language: "swift", code: "let x = 1\n\n# not a heading"),
            .paragraph("After")
        ])
    }

    @Test func unterminatedFenceRendersWhatArrived() {
        #expect(MarkdownText.blocks(of: "```py\nprint(1)") == [.code(language: "py", code: "print(1)")])
        #expect(MarkdownText.blocks(of: "Text\n```") == [.paragraph("Text")])
    }

    @Test func emptyInput() {
        #expect(MarkdownText.blocks(of: "").isEmpty)
        #expect(MarkdownText.blocks(of: "\n\n").isEmpty)
    }
}

struct SelectableTextTests {
    typealias Block = MarkdownText.Block

    @Test func segmentsBreakOnlyAtCodeAndTables() {
        let blocks = MarkdownText.blocks(of: """
        # Title

        Text.

        - item

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        After.
        """)
        #expect(MarkdownText.segments(of: blocks) == [
            .prose([.heading(level: 1, text: "Title"), .paragraph("Text."),
                    .list([.init(marker: .bullet, depth: 0, text: "item")])]),
            .code(language: "swift", code: "let x = 1"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
            .prose([.paragraph("After.")]),
        ])
    }

    @Test func stripsSyntaxAndKeepsStructure() {
        let text = MarkdownText.attributedProse(MarkdownText.blocks(of: """
        # Title

        Some **bold** and `code`, see [docs](https://example.com).

        - one
        - [x] done

        1. first

        ---

        > quoted
        """))
        let string = text.string
        for syntax in ["#", "**", "`", "- one", "[docs]", "](", "---", ">"] {
            #expect(!string.contains(syntax), "found \(syntax)")
        }
        #expect(string.contains("Title"))
        #expect(string.contains("\u{2022}\tone"))
        #expect(string.contains("\u{2611}\tdone"))
        #expect(string.contains("1.\tfirst"))
        #expect(string.contains("quoted"))

        let ns = string as NSString
        let font = text.attribute(.font, at: ns.range(of: "bold").location, effectiveRange: nil) as? SelectableStyle.PlatformFont
        let plain = text.attribute(.font, at: ns.range(of: "Some").location, effectiveRange: nil) as? SelectableStyle.PlatformFont
        #if canImport(UIKit)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        #expect(plain?.fontDescriptor.symbolicTraits.contains(.traitBold) == false)
        #else
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(plain?.fontDescriptor.symbolicTraits.contains(.bold) == false)
        #endif

        let link = text.attribute(.link, at: ns.range(of: "docs").location, effectiveRange: nil) as? URL
        #expect(link == URL(string: "https://example.com"))
    }

    @Test func cachedBlocksRenderTheSameAsFresh() {
        let text = "# Title\n\nSome **bold** text.\n\n- one\n- two\n\n> quoted"
        let first = MarkdownText.attributedProse(MarkdownText.blocks(of: text))
        let second = MarkdownText.attributedProse(MarkdownText.blocks(of: text))
        #expect(first.isEqual(to: second))
        // A longer stream reuses the earlier blocks without changing them.
        let longer = MarkdownText.attributedProse(MarkdownText.blocks(of: text + "\n\nMore."))
        #expect(longer.string.hasPrefix(first.string))
        #expect(ProseBlockCache.count > 0)
    }

    @Test func unsafeLinkSchemesAreNotTappable() {
        let text = MarkdownText.attributedProse(MarkdownText.blocks(of: "[call](tel:+15555550100) or [site](https://example.com)"))
        let ns = text.string as NSString
        #expect(text.attribute(.link, at: ns.range(of: "call").location, effectiveRange: nil) == nil)
        #expect(text.attribute(.link, at: ns.range(of: "site").location, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    }

    @Test func blocksAreSpacedParagraphs() {
        let text = MarkdownText.attributedProse(MarkdownText.blocks(of: "First\nline\n\nSecond"))
        // A soft break stays inside the paragraph; blocks are split by one newline.
        #expect(text.string == "First\u{2028}line\nSecond")
        let first = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let last = text.attribute(.paragraphStyle, at: text.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(first?.paragraphSpacing == SelectableStyle.blockSpacing)
        #expect(last?.paragraphSpacing == 0)
    }

    @Test func copyDropsColoursAndLineSeparators() {
        let text = MarkdownText.attributedProse(MarkdownText.blocks(of: "a\nb"))
        let copy = SelectableText.copyable(text)
        #expect(copy.string == "a\nb")
        #expect(copy.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
    }
}
