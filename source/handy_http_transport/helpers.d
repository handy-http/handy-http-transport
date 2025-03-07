module handy_http_transport.helpers;

import streams;

/**
 * Helper function to consume string content from an input stream until a
 * certain target pattern of characters is encountered.
 * Params:
 *   inputStream = The stream to read from.
 *   target = The target at which to stop reading.
 * Returns: The string that was read, or a stream error.
 */
Either!(string, "value", StreamError, "error") consumeUntil(S)(
    ref S inputStream,
    string target
) if (isByteInputStream!S) {
    ubyte[1024] buffer;
    size_t idx;
    while (true) {
        auto result = inputStream.readFromStream(buffer[idx .. idx + 1]);
        if (result.hasError) return Either!(string, "value", StreamError, "error")(result.error);
        if (result.count != 1) return Either!(string, "value", StreamError, "error")(
            StreamError("Failed to read a single element", 1)
        );
        idx++;
        if (idx >= target.length && buffer[idx - target.length .. idx] == target) {
            return Either!(string, "value", StreamError, "error")(
                cast(string) buffer[0 .. idx - target.length].idup
            );
        }
        if (idx >= buffer.length) {
            return Either!(string, "value", StreamError, "error")(
                StreamError("Couldn't find target \"" ~ target ~ "\" after reading 1024 bytes.", 1)
            );
        }
    }
}

/**
 * Internal helper function to get the first index of a character in a string.
 * Params:
 *   s = The string to look in.
 *   c = The character to look for.
 *   offset = An optional offset to look from.
 * Returns: The index of the character, or -1.
 */
ptrdiff_t indexOf(string s, char c, size_t offset = 0) {
    for (size_t i = offset; i < s.length; i++) {
        if (s[i] == c) return i;
    }
    return -1;
}

/**
 * Internal helper function that returns the slice of a string excluding any
 * preceding or trailing spaces.
 * Params:
 *   s = The string to strip.
 * Returns: The slice of the string that has been stripped.
 */
string stripSpaces(string s) {
    if (s.length == 0) return s;
    ptrdiff_t startIdx = 0;
    while (startIdx < s.length && s[startIdx] == ' ') startIdx++;
    s = s[startIdx .. $];
    if (s.length == 0) return "";
    ptrdiff_t endIdx = s.length - 1;
    while (s[endIdx] == ' ' && endIdx >= 0) endIdx--;
    return s[0 .. endIdx + 1];
}

unittest {
    assert(stripSpaces("") == "");
    assert(stripSpaces("    ") == "");
    assert(stripSpaces("test") == "test");
    assert(stripSpaces("  test") == "test");
    assert(stripSpaces("  test string   ") == "test string");
}

/**
 * Helper function to append an unsigned integer value to a char buffer. It is
 * assumed that there's enough space to write the value.
 * Params:
 *   value = The value to append.
 *   buffer = The buffer to append to.
 *   idx = A reference to a variable tracking the next writable index in the buffer.
 */
void writeUIntToBuffer(uint value, char[] buffer, ref size_t idx) {
    const size_t startIdx = idx;
    while (true) {
        ubyte remainder = value % 10;
        value /= 10;
        buffer[idx++] = cast(char) ('0' + remainder);
        if (value == 0) break;
    }
    // Swap the characters to proper order.
    for (size_t i = 0; i < (idx - startIdx) / 2; i++) {
        size_t p1 = i + startIdx;
        size_t p2 = idx - i - 1;
        char tmp = buffer[p1];
        buffer[p1] = buffer[p2];
        buffer[p2] = tmp;
    }
}
