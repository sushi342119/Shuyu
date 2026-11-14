package app.shuyu.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocalToolsPreferenceAllowlistTest {
    @Test
    fun acceptsAllLibraryAndUiPreferenceKeysIncludingHapticsAndMangaModes() {
        val expectedKeys = listOf(
            "theme",
            "appLanguage",
            "readerFontSize",
            "readerLineHeight",
            "reduceMotion",
            "glassBlur",
            "glassOpacity",
            "readerKeepScreenOn",
            "checkAppUpdates",
            "appTypeface",
            "appFontId",
            "appCustomFont",
            "importedFonts",
            "readerTypeface",
            "appPalette",
            "shelfSort",
            "shelfFilter",
            "localTxtEncoding",
            "hapticPreferences",
            "lowPerformanceMode",
            "performanceGlass",
            "performanceBlur",
            "performanceEdgeBlur",
            "performanceMotion",
            "performanceShelf3d",
            "paletteVariant",
            "glassTier",
            "glassAdvanced",
            "motionLevel",
            "randomPickPace",
            "pdfNightInvert",
            "shelfLayout",
            "tagMatchMode",
            "readerPreferences",
            "mangaBookModes",
            "reader_purification_rules_v1",
            "reader_purification_enabled_v1",
            "reader_paragraph_edits_v1",
            "reading_activity_v1",
            "reading_moments_v1",
            "shelf",
            "reading_history_hidden",
            "recentSearches",
            "local_shelf_removed",
            "tag_defs",
            "tag_map",
            "chapter_1",
            "shelf_added_71",
            "novel_meta_1000000001",
            "reading_position_42",
            "reader_bookmarks_999",
        )
        for (key in expectedKeys) {
            assertTrue("Expected allowlisted key: $key", isAllowedLibraryPreferenceKey(key))
        }
    }

    @Test
    fun rejectsArbitrarySessionAndMalformedRecordKeys() {
        val rejectedKeys = listOf(
            "",
            "TOKEN",
            "cookie",
            "session_cookie",
            "library_restore_journal",
            "chapter_0",
            "chapter_-1",
            "chapter_12345678901",
            "flutter.hapticPreferences",
        )
        for (key in rejectedKeys) {
            assertFalse("Expected rejected key: $key", isAllowedLibraryPreferenceKey(key))
        }
    }
}
