import 'dart:convert';

typedef Json = Map<String, dynamic>;

Json object(dynamic value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid response object');
  }
  return value;
}

List<Json> rows(Json data, String key) {
  final value = data[key] ?? <dynamic>[];
  if (value is! List) throw const FormatException('Invalid inventory list');
  return value.map(object).toList();
}

class BriefingResult {
  BriefingResult(this.json) {
    if (json['requires_confirmation'] != true ||
        json['next_question_tamil'] is! String ||
        json['transcript'] is! String ||
        json['calculations'] is! List ||
        json['warnings'] is! List) {
      throw const FormatException('Invalid briefing response');
    }
    final data = proposal;
    object(data['site']);
    final refs = <String>{};
    for (final key in entityTables.keys) {
      for (final row in rows(data, key)) {
        final ref = row['ref'];
        if (ref is! String || ref.isEmpty || !refs.add(ref)) {
          throw const FormatException('Invalid inventory reference');
        }
      }
    }
    // Keep the UI safe if an incompatible server returns the wrong shape.
    for (final calculation in calculations) {
      if (calculation['nvr_id'] is! String) {
        throw const FormatException('Invalid recorder calculation');
      }
    }
    for (final warning in json['warnings'] as List) {
      if (warning is! String) throw const FormatException('Invalid warning');
    }
  }

  factory BriefingResult.decode(String text) =>
      BriefingResult(object(jsonDecode(text)));
  final Json json;
  Json get proposal => object(json['extracted_data']);
  String get question => json['next_question_tamil'] as String;
  String get transcript => json['transcript'] as String;
  List<Json> get calculations => rows(json, 'calculations');
  List<String> get warnings => (json['warnings'] as List).cast<String>();
}

const entityTables = {
  'contacts': 'site_contacts',
  'floors': 'floors',
  'zones': 'floors_and_zones',
  'assets': 'assets',
  'network_interfaces': 'network_interfaces',
  'cameras': 'cameras',
  'connectivity': 'asset_connections',
};

class WorkItem {
  WorkItem.fromRow(Json row)
    : id = row['id'] as String,
      siteId = row['site_id'] as String,
      text = row['text'] as String?,
      audioPath = row['audio_path'] as String?,
      voiceId = row['voice_id'] as String?,
      language = row['language'] as String,
      attempts = row['attempts'] as int,
      lease = row['lease_token'] as String,
      contextRevision = row['context_revision'] as int? ?? 0;
  final String id, siteId, language, lease;
  final String? text, audioPath, voiceId;
  final int attempts, contextRevision;
}
