const std = @import("std");
const sb = @import("sheen_bidi");

test "sheen_bidi" {
    // Create code point sequence for a sample bidirectional text.
    const bidi_text: []const u8 = "یہ ایک )car( ہے۔";
    const codepoint_sequence: sb.SBCodepointSequence = .{
        .stringEncoding = sb.SBStringEncodingUTF8,
        .stringBuffer = @ptrCast(@constCast(bidi_text.ptr)),
        .stringLength = bidi_text.len,
    };

    // Extract the first bidirectional paragraph.
    const bidi_algorithm: sb.SBAlgorithmRef = sb.SBAlgorithmCreate(&codepoint_sequence);
    defer sb.SBAlgorithmRelease(bidi_algorithm);

    const first_paragraph: sb.SBParagraphRef = sb.SBAlgorithmCreateParagraph(bidi_algorithm, 0, std.math.maxInt(i32), sb.SBLevelDefaultLTR);
    defer sb.SBParagraphRelease(first_paragraph);

    const paragraph_length: sb.SBUInteger = sb.SBParagraphGetLength(first_paragraph);

    // Create a line consisting of whole paragraph and get its runs.
    const paragraph_line: sb.SBLineRef = sb.SBParagraphCreateLine(first_paragraph, 0, paragraph_length);
    defer sb.SBLineRelease(paragraph_line);

    const run_count: sb.SBUInteger = sb.SBLineGetRunCount(paragraph_line);
    const run_array: [*]const sb.SBRun = sb.SBLineGetRunsPtr(paragraph_line);
    const run_slice = run_array[0..run_count];

    // Log the details of each run in the line.
    try std.testing.expectEqualSlices(sb.SBRun, &.{
        .{ .offset = 16, .length = 8, .level = 1 },
        .{ .offset = 13, .length = 3, .level = 2 },
        .{ .offset = 0, .length = 13, .level = 1 },
    }, run_slice);

    // Create a mirror locator and load the line in it.
    const mirror_locator: sb.SBMirrorLocatorRef = sb.SBMirrorLocatorCreate();
    defer sb.SBMirrorLocatorRelease(mirror_locator);

    sb.SBMirrorLocatorLoadLine(mirror_locator, paragraph_line, @ptrCast(@constCast(bidi_text.ptr)));
    const mirror_agent: *const sb.SBMirrorAgent = sb.SBMirrorLocatorGetAgent(mirror_locator);

    // Log the details of each mirror in the line.
    try std.testing.expectEqual(true, sb.SBMirrorLocatorMoveNext(mirror_locator) != 0);
    try std.testing.expectEqual(sb.SBMirrorAgent{ .index = 16, .codepoint = 40, .mirror = 41 }, mirror_agent.*);
    try std.testing.expectEqual(true, sb.SBMirrorLocatorMoveNext(mirror_locator) != 0);
    try std.testing.expectEqual(sb.SBMirrorAgent{ .index = 12, .codepoint = 41, .mirror = 40 }, mirror_agent.*);
    try std.testing.expectEqual(false, sb.SBMirrorLocatorMoveNext(mirror_locator) != 0);

    // Create a script locator and load the codepoints into it.
    const script_locator: sb.SBScriptLocatorRef = sb.SBScriptLocatorCreate();
    defer sb.SBScriptLocatorRelease(script_locator);

    sb.SBScriptLocatorLoadCodepoints(script_locator, &codepoint_sequence);
    const script_agent: *const sb.SBScriptAgent = sb.SBScriptLocatorGetAgent(script_locator);

    // Log the details of each script in the codepoints.
    try std.testing.expectEqual(true, sb.SBScriptLocatorMoveNext(script_locator) != 0);
    try std.testing.expectEqual(sb.SBScriptAgent{ .offset = 0, .length = 13, .script = 4 }, script_agent.*);
    try std.testing.expectEqual(true, sb.SBScriptLocatorMoveNext(script_locator) != 0);
    try std.testing.expectEqual(sb.SBScriptAgent{ .offset = 13, .length = 5, .script = 21 }, script_agent.*);
    try std.testing.expectEqual(true, sb.SBScriptLocatorMoveNext(script_locator) != 0);
    try std.testing.expectEqual(sb.SBScriptAgent{ .offset = 18, .length = 6, .script = 4 }, script_agent.*);
    try std.testing.expectEqual(false, sb.SBScriptLocatorMoveNext(script_locator) != 0);
}
