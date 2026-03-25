import { openDatabaseAsync, type SQLiteDatabase } from 'expo-sqlite';

import type { DownloadRecord } from '@/lib/downloads/types';

let databasePromise: Promise<SQLiteDatabase> | undefined;

async function getDatabase() {
  if (!databasePromise) {
    databasePromise = openDatabaseAsync('cobalt-mobile.db');
  }

  const db = await databasePromise;

  await db.execAsync(`
        CREATE TABLE IF NOT EXISTS downloads (
            id TEXT PRIMARY KEY NOT NULL,
            sourceUrl TEXT NOT NULL,
            remoteUrl TEXT NOT NULL,
            filename TEXT NOT NULL,
            status TEXT NOT NULL,
            localUri TEXT,
            errorMessage TEXT,
            requestJson TEXT NOT NULL,
            responseJson TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        );
    `);

  return db;
}

export async function listDownloads() {
  const db = await getDatabase();
  return db.getAllAsync<DownloadRecord>(
    'SELECT * FROM downloads ORDER BY datetime(createdAt) DESC'
  );
}

export async function insertDownload(record: DownloadRecord) {
  const db = await getDatabase();
  await db.runAsync(
    `INSERT INTO downloads (
            id, sourceUrl, remoteUrl, filename, status, localUri, errorMessage,
            requestJson, responseJson, createdAt, updatedAt
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    [
      record.id,
      record.sourceUrl,
      record.remoteUrl,
      record.filename,
      record.status,
      record.localUri ?? null,
      record.errorMessage ?? null,
      record.requestJson,
      record.responseJson,
      record.createdAt,
      record.updatedAt,
    ]
  );
}

export async function updateDownload(id: string, patch: Partial<DownloadRecord>) {
  const db = await getDatabase();
  const current = await db.getFirstAsync<DownloadRecord>('SELECT * FROM downloads WHERE id = ?', [
    id,
  ]);
  if (!current) {
    return;
  }

  const next = {
    ...current,
    ...patch,
    updatedAt: new Date().toISOString(),
  };

  await db.runAsync(
    `UPDATE downloads SET
            sourceUrl = ?,
            remoteUrl = ?,
            filename = ?,
            status = ?,
            localUri = ?,
            errorMessage = ?,
            requestJson = ?,
            responseJson = ?,
            createdAt = ?,
            updatedAt = ?
         WHERE id = ?`,
    [
      next.sourceUrl,
      next.remoteUrl,
      next.filename,
      next.status,
      next.localUri ?? null,
      next.errorMessage ?? null,
      next.requestJson,
      next.responseJson,
      next.createdAt,
      next.updatedAt,
      id,
    ]
  );
}

export async function deleteDownload(id: string) {
  const db = await getDatabase();
  await db.runAsync('DELETE FROM downloads WHERE id = ?', [id]);
}
