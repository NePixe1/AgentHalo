using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace CodexHalo
{
internal sealed class CodexSQLiteLogStore : IDisposable
    {
        private const int SqliteOpenReadOnly = 0x00000001;
        private const int SqliteRow = 100;
        private const int SqliteDone = 101;
        private readonly object sync = new object();
        private readonly string databasePath;
        private IntPtr connection;
        private bool nativeUnavailable;

        public static readonly CodexSQLiteLogStore Shared =
            new CodexSQLiteLogStore(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".codex", "logs_2.sqlite"));

        internal CodexSQLiteLogStore(string path)
        {
            databasePath = path;
        }

        public List<string> QueryText(string query)
        {
            List<string> rows = new List<string>();
            if (nativeUnavailable || !File.Exists(databasePath))
            {
                return rows;
            }
            lock (sync)
            {
                IntPtr statement = IntPtr.Zero;
                try
                {
                    if (!EnsureConnection())
                    {
                        return rows;
                    }
                    if (sqlite3_prepare_v2(connection, query, -1, out statement,
                        IntPtr.Zero) != 0 || statement == IntPtr.Zero)
                    {
                        ResetConnection();
                        return rows;
                    }
                    int step;
                    while ((step = sqlite3_step(statement)) == SqliteRow)
                    {
                        string value = ReadUtf8Column(statement, 0);
                        if (!String.IsNullOrEmpty(value))
                        {
                            rows.Add(value);
                        }
                    }
                    if (step != SqliteDone)
                    {
                        ResetConnectionAfter(statement);
                        statement = IntPtr.Zero;
                    }
                }
                catch (DllNotFoundException)
                {
                    nativeUnavailable = true;
                    ResetConnection();
                }
                catch (EntryPointNotFoundException)
                {
                    nativeUnavailable = true;
                    ResetConnection();
                }
                catch
                {
                    ResetConnection();
                }
                finally
                {
                    if (statement != IntPtr.Zero)
                    {
                        sqlite3_finalize(statement);
                    }
                }
            }
            return rows;
        }

        private bool EnsureConnection()
        {
            if (connection != IntPtr.Zero)
            {
                return true;
            }
            int opened = sqlite3_open_v2(databasePath, out connection,
                SqliteOpenReadOnly, null);
            if (opened != 0 || connection == IntPtr.Zero)
            {
                ResetConnection();
                return false;
            }
            sqlite3_busy_timeout(connection, 80);
            return true;
        }

        private void ResetConnectionAfter(IntPtr statement)
        {
            if (statement != IntPtr.Zero)
            {
                sqlite3_finalize(statement);
            }
            ResetConnection();
        }

        private void ResetConnection()
        {
            if (connection != IntPtr.Zero)
            {
                sqlite3_close(connection);
                connection = IntPtr.Zero;
            }
        }

        private static string ReadUtf8Column(IntPtr statement, int column)
        {
            IntPtr pointer = sqlite3_column_text(statement, column);
            int length = sqlite3_column_bytes(statement, column);
            if (pointer == IntPtr.Zero || length <= 0)
            {
                return String.Empty;
            }
            byte[] bytes = new byte[length];
            Marshal.Copy(pointer, bytes, 0, length);
            return Encoding.UTF8.GetString(bytes);
        }

        public void Dispose()
        {
            lock (sync)
            {
                ResetConnection();
            }
        }

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_open_v2(string filename,
            out IntPtr database, int flags, string vfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl,
            CharSet = CharSet.Ansi)]
        private static extern int sqlite3_prepare_v2(IntPtr database, string sql,
            int byteCount, out IntPtr statement, IntPtr tail);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_step(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr sqlite3_column_text(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_column_bytes(IntPtr statement, int column);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_finalize(IntPtr statement);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_close(IntPtr database);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern int sqlite3_busy_timeout(IntPtr database,
            int milliseconds);
    }
}
