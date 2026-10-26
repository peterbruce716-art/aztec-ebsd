using System;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Text;
using System.Threading;
using System.Windows;

public static class StaFullMapWorker
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length != 1) { Console.Error.WriteLine("usage: StaFullMapWorker.exe <base64_utf8_script>"); return 2; }
        int result = 1;
        Exception failure = null;
        var thread = new Thread(new ThreadStart(() =>
        {
            try
            {
                var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
                var payload = Encoding.UTF8.GetString(Convert.FromBase64String(args[0]));
                using (var runspace = RunspaceFactory.CreateRunspace())
                {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseNewThread;
                    runspace.Open();
                    using (var ps = PowerShell.Create())
                    {
                        ps.Runspace = runspace;
                        ps.AddScript("$ErrorActionPreference='Stop';" + payload);
                        ps.Invoke();
                        if (ps.HadErrors && ps.Streams.Error.Count > 0)
                            throw ps.Streams.Error[0].Exception ?? new Exception("ps_pipeline_error");
                    }
                }
                app.Shutdown();
                result = 0;
            }
            catch (Exception ex) { failure = ex; }
        }));
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure != null) { Console.Error.WriteLine(failure.ToString()); return 1; }
        return result;
    }
}
