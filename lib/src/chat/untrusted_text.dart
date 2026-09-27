/// Inspection and cleanup for message text received from other devices.
///
/// Message text is attacker-controlled. Invisible characters let a sender
/// hide content from the person reading it while software, notably an LLM
/// that summarizes or answers messages, still reads it:
///
/// * Unicode tag characters (U+E0000–U+E007F) spell out ASCII invisibly
///   ("ASCII smuggling");
/// * long runs of variation selectors encode arbitrary bytes after a single
///   visible character;
/// * bidirectional overrides and isolates reorder what is displayed
///   ("Trojan Source");
/// * zero-width and filler characters hide or split words.
///
/// Legitimate uses survive: emoji ZWJ sequences, a single variation selector
/// after a character (❤️), tag sequences in subdivision flags (🏴󠁧󠁢󠁥󠁮󠁧󠁿),
/// ZWNJ in Persian and Indic scripts, and LRM/RLM marks.
///
/// Stripping protects what a human sees. It does not make text safe to use
/// as instructions: a host that passes messages to an LLM must still treat
/// them as untrusted data.
abstract final class UntrustedText {
  /// Whether [text] contains characters that [stripHidden] would remove.
  static bool hasHiddenCharacters(String text) => stripHidden(text) != text;

  /// [text] with hidden, reordering, and smuggling characters removed.
  static String stripHidden(String text) {
    final runes = text.runes.toList(growable: false);
    final output = StringBuffer();
    var previousWasVariationSelector = false;
    var index = 0;
    while (index < runes.length) {
      final rune = runes[index];
      if (rune == _blackFlag) {
        final end = _tagSequenceEnd(runes, index + 1);
        if (end != null) {
          for (var i = index; i < end; i++) {
            output.writeCharCode(runes[i]);
          }
          index = end;
          previousWasVariationSelector = false;
          continue;
        }
      }
      index++;
      if (_isVariationSelector(rune)) {
        // One selector picks a glyph variant; a run of them carries data.
        if (!previousWasVariationSelector && output.isNotEmpty) {
          output.writeCharCode(rune);
        }
        previousWasVariationSelector = true;
        continue;
      }
      previousWasVariationSelector = false;
      if (_isHidden(rune)) continue;
      output.writeCharCode(rune);
    }
    return output.toString();
  }

  static const _blackFlag = 0x1f3f4;

  /// End (exclusive) of a valid emoji tag sequence starting at [start], or
  /// null. A valid sequence is 1–32 tag characters then CANCEL TAG.
  static int? _tagSequenceEnd(List<int> runes, int start) {
    var index = start;
    while (index < runes.length &&
        index - start < 32 &&
        runes[index] >= 0xe0020 &&
        runes[index] <= 0xe007e) {
      index++;
    }
    if (index == start || index >= runes.length || runes[index] != 0xe007f) {
      return null;
    }
    return index + 1;
  }

  static bool _isVariationSelector(int rune) =>
      (rune >= 0xfe00 && rune <= 0xfe0f) ||
      (rune >= 0xe0100 && rune <= 0xe01ef);

  static bool _isHidden(int rune) =>
      // C0 controls except tab and newline, DEL, and C1 controls.
      (rune < 0x20 && rune != 0x09 && rune != 0x0a) ||
      (rune >= 0x7f && rune <= 0x9f) ||
      // Tag characters outside a flag sequence.
      (rune >= 0xe0000 && rune <= 0xe007f) ||
      // Bidirectional embeddings, overrides, and isolates.
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069) ||
      // Zero-width space, word joiner, invisible operators, deprecated
      // format characters, byte-order mark.
      rune == 0x200b ||
      (rune >= 0x2060 && rune <= 0x2064) ||
      (rune >= 0x206a && rune <= 0x206f) ||
      rune == 0xfeff ||
      // Characters that render as nothing in most fonts.
      rune == 0x034f ||
      rune == 0x115f ||
      rune == 0x1160 ||
      rune == 0x17b4 ||
      rune == 0x17b5 ||
      rune == 0x180e ||
      rune == 0x3164 ||
      rune == 0xffa0 ||
      // Interlinear annotation controls.
      (rune >= 0xfff9 && rune <= 0xfffb);
}
