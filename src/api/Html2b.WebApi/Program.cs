using Html2b.WebApi.Rendering;

namespace Html2b.WebApi
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var builder = WebApplication.CreateBuilder(args);

            builder.Services.AddControllers();
            builder.Services.AddTransient<ChromiumRenderer>();

            var app = builder.Build();

            app.MapControllers();

            app.Run();
        }
    }
}
