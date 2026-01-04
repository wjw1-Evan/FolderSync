using FolderSync.Data.Entities;
using Microsoft.EntityFrameworkCore;

namespace FolderSync.Data;

public class FolderSyncDbContext : DbContext
{
    public FolderSyncDbContext(DbContextOptions<FolderSyncDbContext> options) : base(options)
    {
    }

    public DbSet<ClientIdentity> ClientIdentities => Set<ClientIdentity>();
    public DbSet<SyncConfiguration> SyncConfigurations => Set<SyncConfiguration>();
    public DbSet<FileMetadata> FileMetadatas => Set<FileMetadata>();
    public DbSet<FileVersion> FileVersions => Set<FileVersion>();
    public DbSet<SyncHistory> SyncHistories => Set<SyncHistory>();
    public DbSet<PeerDevice> PeerDevices => Set<PeerDevice>();
    public DbSet<SyncConflict> SyncConflicts => Set<SyncConflict>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        base.OnModelCreating(modelBuilder);

        // ClientIdentity
        modelBuilder.Entity<ClientIdentity>()
            .HasIndex(c => c.ClientId)
            .IsUnique();

        // SyncConfiguration
        modelBuilder.Entity<SyncConfiguration>()
            .HasMany(s => s.Files)
            .WithOne(f => f.SyncConfig)
            .HasForeignKey(f => f.SyncConfigId)
            .OnDelete(DeleteBehavior.Cascade);

        // FileMetadata
        modelBuilder.Entity<FileMetadata>()
            .HasIndex(f => new { f.SyncConfigId, f.FilePath })
            .IsUnique();

        modelBuilder.Entity<FileMetadata>()
            .HasMany(f => f.Versions)
            .WithOne(v => v.FileMetadata)
            .HasForeignKey(v => v.FileMetadataId)
            .OnDelete(DeleteBehavior.Cascade);

        // FileVersion
        modelBuilder.Entity<FileVersion>()
            .HasIndex(v => new { v.FileMetadataId, v.VersionNumber })
            .IsUnique();

        // PeerDevice
        modelBuilder.Entity<PeerDevice>()
            .HasIndex(p => p.DeviceId)
            .IsUnique();
        
        // SyncHistory
        modelBuilder.Entity<SyncHistory>()
            .HasIndex(h => h.Timestamp);
    }
}
