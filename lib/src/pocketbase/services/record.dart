// ignore_for_file: public_member_api_docs, sort_constructors_first
import 'dart:async';

import "package:http/http.dart" as http;
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../../database/database.dart';
import '../pocketbase.dart';

typedef IdGenerator = String Function();

// TODO: Files to path provider, web?
class $RecordService extends RecordService {
  $RecordService(this.client, this.collection) : super(client, collection.id);

  @override
  final $PocketBase client;

  final CollectionModel collection;

  Stream<RetryProgressEvent?> retryLocal({
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async* {
    final deleted = await client.db.recordsDao.getPendingDeletes();
    final fresh = await client.db.recordsDao.getPendingWrites();
    final pending = await client.db.recordsDao.getPending();
    yield RetryProgressEvent(
      message: 'Found ${pending.length} pending records',
      total: pending.length,
      current: 0,
    );
    final futures = <Future>[];
    for (final item in pending) {
      futures.add(Future(() async {
        try {
          final isDeleted = deleted.indexWhere((e) => e.id == item.id) != -1;
          final isFresh = fresh.indexWhere((e) => e.id == item.id) != -1;
          if (isDeleted) {
            await delete(
              item.id,
              query: query,
              headers: headers,
              body: item.data,
            );
          } else if (isFresh) {
            await create(
              query: query,
              headers: headers,
              body: item.data,
            );
          } else {
            await update(
              item.id,
              query: query,
              headers: headers,
              body: item.data,
              merge: (current, remote) {
                final remoteDate = DateTime.parse(remote.updated);
                final currentDate = DateTime.parse(current.updated);
                if (remoteDate.isAfter(currentDate)) {
                  return remote;
                } else {
                  return current;
                }
              },
            );
          }
        } catch (e) {
          if (client.logging) debugPrint('retryLocal: ${item.id} $e');
        }
      }));
    }
    for (final item in futures) {
      yield RetryProgressEvent(
        message: 'Updating record',
        total: pending.length,
        current: futures.indexOf(item) + 1,
      );
      await item;
    }
    await client.db.recordsDao.removeSyncedDeletedRecords();
    yield null;
  }

  Future<void> setLocal(List<Map<String, dynamic>> list) async {
    final items = list.map((e) {
      return RecordModel(
        id: e['id'] ?? client.idGenerator(),
        data: e,
        collectionId: collection.id,
        collectionName: collection.name,
        created: e['created'] ?? DateTime.now().toIso8601String(),
        updated: e['updated'] ?? DateTime.now().toIso8601String(),
      );
    }).toList();
    await client.db.recordsDao.addAll(collection.toModel(), items);
  }

  Future<List<RecordModel>> search(String query) {
    return client.db.search(query, collectionId: collection.id);
  }

  Future<void> onEvent(RecordSubscriptionEvent e) async {
    if (e.record != null) {
      if (e.action == 'create') {
        await client.db.recordsDao.createRecord(
          collection: collection.toModel(),
          id: e.record!.id,
          data: e.record!.data,
          deleted: false,
          synced: true,
        );
      } else if (e.action == 'update') {
        await client.db.recordsDao.updateRecord(
          collection: collection.toModel(),
          id: e.record!.id,
          data: e.record!.data,
          deleted: false,
          synced: true,
        );
      } else if (e.action == 'delete') {
        await client.db.recordsDao.updateRecord(
          collection: collection.toModel(),
          id: e.record!.id,
          data: e.record!.data,
          deleted: true,
          synced: true,
        );
      }
    }
  }

  StreamController<RecordModel?> watchRecord(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    bool deleted = false,
    bool? synced,
  }) {
    UnsubscribeFunc? cancel;
    final controller = StreamController<RecordModel?>.broadcast(
      onListen: () async {
        if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
            fetchPolicy == FetchPolicy.networkOnly) {
          try {
            cancel = await subscribe(id, onEvent);
          } catch (e) {
            if (client.logging) debugPrint('watchRecord: $e');
          }
        }
      },
      onCancel: () async {
        await cancel?.call();
      },
    );
    controller.addStream(client.db.recordsDao.watchRecord(
      collectionId: collection.id,
      id: id,
    ));
    return controller;
  }

  StreamController<List<RecordModel>> watchRecords({
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    bool deleted = false,
    bool? synced,
  }) {
    UnsubscribeFunc? cancel;
    final controller = StreamController<List<RecordModel>>.broadcast(
      onListen: () async {
        if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
            fetchPolicy == FetchPolicy.networkOnly) {
          try {
            cancel = await subscribe('*', onEvent);
          } catch (e) {
            if (client.logging) debugPrint('watchRecord: $e');
          }
        }
        await getFullList(fetchPolicy: fetchPolicy);
      },
      onCancel: () async {
        await cancel?.call();
      },
    );
    controller.addStream(client.db.recordsDao.watchAll(
      collectionId: collection.id,
      deleted: deleted,
      synced: synced,
    ));
    return controller;
  }

  @override
  Future<List<RecordModel>> getFullList({
    int batch = 200,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    bool deleted = false,
    bool? synced,
  }) async {
    List<RecordModel> items = [];

    if (fetchPolicy == FetchPolicy.networkOnly ||
        fetchPolicy == FetchPolicy.cacheAndNetwork) {
      try {
        items = await super.getFullList(
          batch: batch,
          expand: expand,
          filter: filter,
          fields: fields,
          sort: sort,
          query: query,
          headers: headers,
        );
      } catch (e) {
        throw Exception(
          'Failed to get records in collection $collection.name $e',
        );
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork) {
      if (items.isNotEmpty) {
        await client.db.recordsDao.addAll(
          collection.toModel(),
          items,
          synced: synced,
          deleted: deleted,
        );
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.cacheOnly) {
      if (items.isEmpty) {
        items = await client.db.recordsDao.getAll(
          collectionId: collection.id,
          deleted: deleted,
          synced: synced,
        );
      }
    }

    return items;
  }

  @override
  Future<ResultList<RecordModel>> getList({
    int page = 1,
    int perPage = 30,
    String? expand,
    String? filter,
    String? sort,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    bool deleted = false,
    bool? synced,
  }) async {
    ResultList<RecordModel> result = ResultList(items: []);
    if (fetchPolicy == FetchPolicy.networkOnly ||
        fetchPolicy == FetchPolicy.cacheAndNetwork) {
      try {
        result = await super.getList(
          page: page,
          perPage: perPage,
          expand: expand,
          filter: filter,
          fields: fields,
          sort: sort,
          query: query,
          headers: headers,
        );
      } catch (e) {
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(
            'Failed to get records in collection $collection.name $e',
          );
        }
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork) {
      if (result.items.isNotEmpty) {
        await client.db.recordsDao.addAll(collection.toModel(), result.items);
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.cacheOnly) {
      if (result.items.isEmpty) {
        final items = await client.db.recordsDao.getAll(
          collectionId: collection.id,
          deleted: deleted,
          synced: synced,
          page: page,
          perPage: perPage,
        );
        final count = await client.db.recordsDao.getRecordCount(
          collectionId: collection.id,
          deleted: deleted,
          synced: synced,
        );
        result = ResultList(
          page: page,
          perPage: perPage,
          items: items,
          totalItems: count,
          totalPages: (count / perPage).floor(),
        );
      }
    }

    return result;
  }

  @override
  Future<RecordModel> getOne(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    String? expand,
    String? fields,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    RecordModel? record;
    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.networkOnly) {
      try {
        record = await super.getOne(
          id,
          expand: expand,
          query: query,
          headers: headers,
          fields: fields,
        );
      } catch (e) {
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(
            'Failed to get record $id in collection $collection.name $e',
          );
        }
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.cacheOnly) {
      final model = await client.db.recordsDao.getRecord(
        collectionId: collection.id,
        id: id,
        deleted: false,
      );
      if (model != null) {
        record = model;
      }
    }

    if (record == null) {
      throw Exception(
        'Record $id does not exist in collection $collection.name',
      );
    }

    return record;
  }

  @override
  Future<void> delete(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    if (fetchPolicy == FetchPolicy.cacheAndNetwork) {
      await client.db.recordsDao.deleteRecord(
        id: id,
        collectionId: collection.id,
      );
    }
    RecordModel? record = await client.db.recordsDao.getRecord(
      collectionId: collection.id,
      id: id,
    );
    if (fetchPolicy == FetchPolicy.cacheOnly && record != null) {
      await client.db.recordsDao.updateRecord(
        collection: collection.toModel(),
        id: record.id,
        data: record.data,
        deleted: true,
        synced: false,
      );
    }
    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.networkOnly) {
      try {
        await super.delete(
          id,
          body: body,
          query: query,
          headers: headers,
        );
      } catch (e) {
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(
            'Failed to delete record $id in collection $collection.name $e',
          );
        }
      }
    }
  }

  @override
  Future<RecordModel> update(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<http.MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
    RecordModel? Function(RecordModel current, RecordModel remote)? merge,
  }) async {
    RecordModel? record = await client.db.recordsDao.getRecord(
      collectionId: collection.id,
      id: id,
    );
    bool saved = false;
    if (record == null && fetchPolicy == FetchPolicy.cacheAndNetwork) {
      record = await super.getOne(
        id,
        expand: expand,
        query: query,
        headers: headers,
        fields: fields,
      );
    }
    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.networkOnly) {
      try {
        if (merge != null) {
          final remote = await getOneOrNull(
            id,
            expand: expand,
            query: query,
            headers: headers,
            fetchPolicy: FetchPolicy.networkOnly,
          );
          if (record != null) {
            record = merge(record, remote!);
          } else {
            record = remote;
          }
        }
        record = await super.update(
          id,
          body: body,
          query: query,
          headers: headers,
          expand: expand,
          files: files,
          fields: fields,
        );
        saved = true;
      } catch (e) {
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(
            'Failed to update record $id in collection $collection.name $e',
          );
        }
      }
    }
    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.cacheOnly) {
      if (record == null) {
        throw Exception(
          'Record $id does not exist in collection $collection.name',
        );
      }
      record.data.addAll(body);
      await client.db.recordsDao.updateRecord(
        collection: collection.toModel(),
        id: record.id,
        data: record.data,
        synced: saved,
      );
    }
    return record!;
  }

  @override
  Future<RecordModel> create({
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    Map<String, dynamic> body = const {},
    Map<String, dynamic> query = const {},
    List<http.MultipartFile> files = const [],
    Map<String, String> headers = const {},
    String? expand,
    String? fields,
  }) async {
    RecordModel? record;
    bool saved = false;

    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.networkOnly) {
      try {
        record = await super.create(
          body: body,
          query: query,
          headers: headers,
          expand: expand,
          files: files,
          fields: fields,
        );
        saved = true;
      } catch (e) {
        if (fetchPolicy == FetchPolicy.networkOnly) {
          throw Exception(
            'Failed to create record ${record?.id} in collection $collection.name $e',
          );
        }
      }
    }

    if (fetchPolicy == FetchPolicy.cacheAndNetwork ||
        fetchPolicy == FetchPolicy.cacheOnly) {
      final result = await client.db.recordsDao.createRecord(
        collection: collection.toModel(),
        data: body,
        synced: saved,
        deleted: false,
        id: record?.id,
      );
      record = await client.db.recordsDao.getRecord(
        collectionId: collection.id,
        id: result,
      );
    }

    return record!;
  }

  RecordModel toRecord(Map<String, dynamic> data) {
    final id = data['id'].toString();
    return RecordModel(
      id: id,
      data: data,
      created: DateTime.now().toIso8601String(),
      updated: DateTime.now().toIso8601String(),
      collectionId: collection.id,
      collectionName: collection.name,
    );
  }
}

enum FetchPolicy {
  cacheOnly,
  networkOnly,
  cacheAndNetwork,
}

extension RecordServiceUtils on $RecordService {
  Future<RecordModel?> getOneOrNull(
    String id, {
    FetchPolicy fetchPolicy = FetchPolicy.cacheAndNetwork,
    String? expand,
    Map<String, dynamic> query = const {},
    Map<String, String> headers = const {},
  }) async {
    try {
      final result = await getOne(
        id,
        fetchPolicy: fetchPolicy,
        expand: expand,
        query: query,
        headers: headers,
      );
      return result;
    } catch (e) {
      if (client.logging) {
        debugPrint('cannot find $id in $collection.name $e');
      }
    }
    return null;
  }
}

class RetryProgressEvent {
  final int total;
  final int current;
  final String message;

  const RetryProgressEvent({
    required this.total,
    required this.current,
    required this.message,
  });

  double get progress => current / total;
}
