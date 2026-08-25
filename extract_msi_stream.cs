using System;
using System.IO;
using System.Runtime.InteropServices;

// Minimal read-only extractor for a named stream in an MSI/MSP database.
// It uses only the Windows Installer API shipped with Windows.
internal static class ExtractMsiStream
{
    private const uint ErrorSuccess = 0;
    private const uint ErrorNoMoreItems = 259;

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiOpenDatabaseW(
        string databasePath,
        IntPtr persist,
        out IntPtr database);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    private static extern uint MsiDatabaseOpenViewW(
        IntPtr database,
        string query,
        out IntPtr view);

    [DllImport("msi.dll")]
    private static extern uint MsiViewExecute(IntPtr view, IntPtr record);

    [DllImport("msi.dll")]
    private static extern uint MsiViewFetch(IntPtr view, out IntPtr record);

    [DllImport("msi.dll")]
    private static extern uint MsiRecordDataSize(IntPtr record, uint field);

    [DllImport("msi.dll")]
    private static extern uint MsiRecordReadStream(
        IntPtr record,
        uint field,
        [Out] byte[] buffer,
        ref uint bufferSize);

    [DllImport("msi.dll")]
    private static extern uint MsiCloseHandle(IntPtr handle);

    private static void Check(uint result, string operation)
    {
        if (result != ErrorSuccess)
            throw new InvalidOperationException(operation + " failed with MSI error " + result);
    }

    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: extract_msi_stream DATABASE STREAM OUTPUT");
            return 2;
        }

        IntPtr database = IntPtr.Zero;
        IntPtr view = IntPtr.Zero;
        IntPtr record = IntPtr.Zero;
        try
        {
            Check(MsiOpenDatabaseW(args[0], IntPtr.Zero, out database), "MsiOpenDatabase");
            string escaped = args[1].Replace("'", "''");
            string query = "SELECT `Data` FROM `_Streams` WHERE `Name`='" + escaped + "'";
            Check(MsiDatabaseOpenViewW(database, query, out view), "MsiDatabaseOpenView");
            Check(MsiViewExecute(view, IntPtr.Zero), "MsiViewExecute");
            uint fetched = MsiViewFetch(view, out record);
            if (fetched == ErrorNoMoreItems)
                throw new InvalidOperationException("MSI stream not found: " + args[1]);
            Check(fetched, "MsiViewFetch");

            uint expected = MsiRecordDataSize(record, 1);
            byte[] payload = new byte[expected];
            uint actual = expected;
            Check(MsiRecordReadStream(record, 1, payload, ref actual), "MsiRecordReadStream");
            if (actual != expected)
                throw new InvalidOperationException("short MSI stream: expected " + expected + ", read " + actual);
            File.WriteAllBytes(args[2], payload);
            Console.WriteLine(args[1] + "\t" + actual + "\t" + args[2]);
            return 0;
        }
        finally
        {
            if (record != IntPtr.Zero) MsiCloseHandle(record);
            if (view != IntPtr.Zero) MsiCloseHandle(view);
            if (database != IntPtr.Zero) MsiCloseHandle(database);
        }
    }
}
