namespace FolderSync.Core.Interfaces;

public interface IAuthenticationService
{
    Task<bool> IsAuthenticationEnabledAsync();
    Task SetPinAsync(string pin);
    Task<bool> VerifyPinAsync(string pin);
    Task RemovePinAsync();
}
