import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';

import 'app_ui.dart';
import 'app_interactions.dart';
import 'archive_wave.dart';
import 'novel_random_pick_section.dart';
import 'backup_page.dart';
import 'book_edit_page.dart';
import 'book_tags.dart';
import 'catalog.dart';
import 'glass_dock.dart';
import 'haptic_preferences.dart';
import 'library_state.dart';
import 'listening/controller.dart';
import 'listening/models.dart' show hasSpeechText;
import 'listening/widgets.dart';
import 'local_platform.dart';
import 'native_effects.dart' show NativeGlassGroup;
import 'novel_feed_controller.dart';
import 'offline_repository.dart';
import 'offline_widgets.dart';
import 'reader_catalogue.dart';
import 'reader_chrome.dart';
import 'ui_preferences.dart';
import 'reader_skeleton.dart';
import 'library_filter.dart';
import 'reader_preferences.dart' show ReaderPaper, ReaderMode;
import 'reader_paged_view.dart' show ReaderPagedController, ReaderPagedView;
import 'reader_pagination.dart' show ReaderPageFragment, ReaderTextAnchor;
import 'reader_paging.dart';
import 'reader_content.dart';
import 'reader_rich_content.dart'
    show
        ReaderRichParagraph,
        ReaderEmphasis,
        ReaderRuby,
        ReaderNoteReference;
import 'reader_illustrations.dart';
import 'reader_find.dart';
import 'reader_purification.dart';
import 'reader_annotation_editor.dart';
import 'reader_selection.dart';
import 'reader_text_picker.dart';
import 'reader_tools.dart';
import 'reader_underline.dart';
import 'reading_statistics_data.dart';
import 'reading_activity.dart';
import 'reading_history.dart';
import 'reading_statistics_page.dart';
import 'bookmark_library_page.dart';
import 'font_settings_page.dart';
import 'palette_settings_page.dart';
import 'reading_widget_settings_page.dart';
import 'ui_notifiers.dart';
import 'feature_pages.dart';
import 'local_library.dart';
import 'local_record_removal.dart';
import 'local_scan_follow_up.dart';
import 'local_library_page.dart';
import 'local_duplicates_page.dart';
import 'local_pdf_reader.dart';
import 'local_epub_reader.dart';
import 'text_anchor.dart';
import 'tag_pages.dart';
import 'updates/update_page.dart';
import 'updates/app_updates.dart';
import 'wenku_errors.dart';

export 'app_ui.dart' show sectionHeader;
export 'reader_underline.dart'
    show readerRegistrationBounds, paintReaderRegistrationFrame;


part 'home_shell.dart';
part 'discover_page.dart';
part 'shelf_page.dart';
part 'settings_page.dart';
part 'detail_page.dart';
part 'reader_page.dart';
part 'reader_page_persistence.dart';
part 'reader_page_widgets.dart';
