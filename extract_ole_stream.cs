using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using ComStatStg = System.Runtime.InteropServices.ComTypes.STATSTG;

// Minimal read-only extractor for a named root stream in an OLE compound file.
// MSP files are structured storages, so this uses the Windows Structured Storage
// API directly and never applies or installs the patch.
internal static class ExtractOleStream
{
    private const uint StgmRead = 0x00000000;
    private const uint StgmShareDenyWrite = 0x00000020;
    private const uint StgmShareExclusive = 0x00000010;

    [ComImport]
    [Guid("0000000D-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface CompoundIEnumStatStg
    {
        [PreserveSig]
        int Next(
            uint count,
            [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] ComStatStg[] elements,
            out uint fetched);
        void Skip(uint count);
        void Reset();
        void Clone([MarshalAs(UnmanagedType.Interface)] out CompoundIEnumStatStg clone);
    }

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

        void CreateStorage(
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            uint mode,
            uint reserved1,
            uint reserved2,
            [MarshalAs(UnmanagedType.Interface)] out CompoundIStorage storage);

        void OpenStorage(
            [MarshalAs(UnmanagedType.LPWStr)] string name,
            IntPtr priority,
            uint mode,
            IntPtr exclude,
            uint reserved,
            [MarshalAs(UnmanagedType.Interface)] out CompoundIStorage storage);

        void CopyTo(uint count, IntPtr exclusions, IntPtr names, CompoundIStorage destination);
        void MoveElementTo([MarshalAs(UnmanagedType.LPWStr)] string name, CompoundIStorage destination,
            [MarshalAs(UnmanagedType.LPWStr)] string newName, uint flags);
        void Commit(uint flags);
        void Revert();
        void EnumElements(uint reserved1, IntPtr reserved2, uint reserved3,
            [MarshalAs(UnmanagedType.Interface)] out CompoundIEnumStatStg enumerator);

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
            Console.Error.WriteLine("usage: extract_ole_stream STORAGE EXPECTED_STREAM_SIZE OUTPUT");
            return 2;
        }

        CompoundIStorage storage = null;
        IStream stream = null;
        CompoundIEnumStatStg enumerator = null;
        IntPtr bytesRead = IntPtr.Zero;
        try
        {
            long expectedSize;
            if (!long.TryParse(args[1], out expectedSize) || expectedSize <= 0)
                throw new ArgumentException("invalid expected stream size: " + args[1]);
            int result = StgOpenStorage(args[0], IntPtr.Zero, StgmRead | StgmShareDenyWrite,
                IntPtr.Zero, 0, out storage);
            Check(result, "StgOpenStorage");

            storage.EnumElements(0, IntPtr.Zero, 0, out enumerator);
            string selectedName = null;
            int selectedCount = 0;
            while (true)
            {
                ComStatStg[] element = new ComStatStg[1];
                uint fetched;
                result = enumerator.Next(1, element, out fetched);
                Check(result, "IEnumSTATSTG.Next");
                if (fetched == 0)
                    break;
                Console.WriteLine("element\t" + element[0].type + "\t" + element[0].cbSize + "\t" + element[0].pwcsName);
                if (element[0].type == 2 && element[0].cbSize == expectedSize)
                {
                    selectedName = element[0].pwcsName;
                    selectedCount++;
                }
            }
            if (selectedCount != 1)
                throw new InvalidOperationException("expected exactly one root stream of size " + expectedSize + ", found " + selectedCount);
            Marshal.FinalReleaseComObject(enumerator);
            enumerator = null;

            storage.OpenStream(selectedName, IntPtr.Zero, StgmRead | StgmShareExclusive, 0, out stream);

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
            Console.WriteLine("selected\t" + selectedName + "\t" + total + "\t" + args[2]);
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
            if (enumerator != null) Marshal.FinalReleaseComObject(enumerator);
            if (stream != null) Marshal.FinalReleaseComObject(stream);
            if (storage != null) Marshal.FinalReleaseComObject(storage);
        }
    }
}
