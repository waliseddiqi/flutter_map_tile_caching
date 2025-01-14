// Copyright © Luka S (JaffaKetchup) under GPL-v3
// A full license can be found at .\LICENSE

import 'dart:io';

import 'package:isar/isar.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'package:stream_transform/stream_transform.dart';

import '../../flutter_map_tile_caching.dart';
import '../misc/exts.dart';
import 'defs/metadata.dart';
import 'defs/recovery.dart';
import 'defs/store_descriptor.dart';
import 'defs/tile.dart';

/// Manages the stores available
///
/// It is very important for the [storeDatabases] state to remain in sync with
/// the actual state of the [directory], otherwise unexpected behaviour may
/// occur.
@internal
class FMTCRegistry {
  const FMTCRegistry._({
    required this.directory,
    required this.recoveryDatabase,
    required this.storeDatabases,
  });

  static late FMTCRegistry instance;

  final Directory directory;
  final Isar recoveryDatabase;
  final Map<int, Isar> storeDatabases;

  static Future<FMTCRegistry> initialise({
    required Directory directory,
    required int databaseMaxSize,
    required CompactCondition? databaseCompactCondition,
    void Function(FMTCInitialisationException error)? errorHandler,
    IOSink? initialisationSafetyWriteSink,
    List<String>? safeModeSuccessfulIDs,
  }) async {
    bool hasLocatedCorruption = false;

    if (safeModeSuccessfulIDs != null) {
      await (directory >>> '.recovery.isar').delete();
    }

    await directory
        .list()
        .where((e) => e is File && path.basename(e.path).endsWith('-lck'))
        .asyncMap((f) => f.delete())
        .toList();

    return instance = FMTCRegistry._(
      directory: directory,
      recoveryDatabase: await Isar.open(
        [DbRecoverableRegionSchema],
        name: '.recovery',
        directory: directory.absolute.path,
        maxSizeMiB: databaseMaxSize,
        compactOnLaunch: databaseCompactCondition,
      ),
      storeDatabases: Map.fromEntries(
        await directory
            .list()
            .where(
              (e) =>
                  e is File &&
                  !path.basename(e.path).startsWith('.') &&
                  !path.basename(e.path).endsWith('-lck'),
            )
            .asyncMap((f) async {
              final id = path.basenameWithoutExtension(f.path);

              if (!hasLocatedCorruption &&
                  safeModeSuccessfulIDs != null &&
                  !safeModeSuccessfulIDs.contains(id)) {
                await f.delete();
                hasLocatedCorruption = true;
                errorHandler?.call(
                  FMTCInitialisationException(
                    source: null,
                  ),
                );
                return null;
              }

              final MapEntry<int, Isar> entry;
              try {
                entry = MapEntry(
                  int.parse(id),
                  await Isar.open(
                    [DbStoreDescriptorSchema, DbTileSchema, DbMetadataSchema],
                    name: id,
                    directory: directory.absolute.path,
                    maxSizeMiB: databaseMaxSize,
                    compactOnLaunch: databaseCompactCondition,
                  ),
                );
                initialisationSafetyWriteSink?.writeln(id);
                await initialisationSafetyWriteSink?.flush();
              } catch (err) {
                errorHandler?.call(
                  FMTCInitialisationException(source: err),
                );
                return null;
              }

              return entry;
            })
            .whereNotNull()
            .toList(),
      ),
    );
  }

  Future<void> uninitialise({bool delete = false}) async {
    await Future.wait<void>([
      ...FMTC.instance.rootDirectory.stats.storesAvailable
          .map((s) => s.manage.delete()),
      recoveryDatabase.close(deleteFromDisk: delete),
    ]);
  }
}
