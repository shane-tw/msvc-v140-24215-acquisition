using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// Minimal read-only extractor for a named root stream in an OLE compound file.
// MSP files are structured storages, so this uses the Windows Structured Storage
// API directly and never applies or installs the patch.
internal static class ExtractOleStream
{
    private const uint StgmRead = 0x00000000;
    private const uint StgmShareDenyWrite = 0x00000020;
    private const uint StgmShareExclusive = 0x00000010;

    [ComImport]
    [Guid("0000000B-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface CompoundIStorage
    {
        void CreateStream(
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            uint mode,
            uint reserved1,
            uint reserved2,
            [MarshalAs(UnmanagedType.Interface)] out IStream stream);

        void OpenStream(
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            IntPtr reserved1,
            uint mode,
            uint reserved2,
            [MarshalAs(UnmanagedType.Interface)] out IStream stream);

    }

    [DllImport("ole32.dll", CharSet = CharSet.Unicode)]
    private static extern int StgOpenStorage(
        string name,
        IntPtr priority,
        uint mode,
        IntPtr exclude,
        uint reserved,
        [MarshalAs(UnmanagedType.Interface)] out CompoundIStorage storage);

    private static void Check(int result, string operation)
    {
        if (result < 0)
            Marshal.ThrowExceptionForHR(result);
    }

    public static int Main(string[] args)
    {
        if (args.Length != 3)
        {
            Console.Error.WriteLine("usage: extract_ole_stream STORAGE STREAM OUTPUT");
            return 2;
        }

        CompoundIStorage storage = null;
        IStream stream = null;
        IntPtr bytesRead = IntPtr.Zero;
        try
        {
            int result = StgOpenStorage(args[0], IntPtr.Zero, StgmRead | StgmShareDenyWrite,
                IntPtr.Zero, 0, out storage);
            Check(result, "StgOpenStorage");
            storage.OpenStream(args[1], IntPtr.Zero, StgmRead | StgmShareExclusive, 0, out stream);

            bytesRead = Marshal.AllocCoTaskMem(sizeof(int));
            byte[] buffer = new byte[1024 * 1024];
            long total = 0;
            using (FileStream output = new FileStream(args[2], FileMode.Create, FileAccess.Write, FileShare.None))
            {
                while (true)
                {
                    Marshal.WriteInt32(bytesRead, 0);
                    stream.Read(buffer, buffer.Length, bytesRead);
                    int count = Marshal.ReadInt32(bytesRead);
                    if (count == 0)
                        break;
                    output.Write(buffer, 0, count);
                    total += count;
                }
            }
            Console.WriteLine(args[1] + "\t" + total + "\t" + args[2]);
            return 0;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(exception.ToString());
            return 1;
        }
        finally
        {
            if (bytesRead != IntPtr.Zero) Marshal.FreeCoTaskMem(bytesRead);
            if (stream != null) Marshal.FinalReleaseComObject(stream);
            if (storage != null) Marshal.FinalReleaseComObject(storage);
        }
    }
}
