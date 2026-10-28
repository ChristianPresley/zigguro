//! zg_git: a from-scratch implementation of git's on-disk formats (E09.F07)
//! for colocation with existing repositories. Pure Zig std; no git binary.

const std = @import("std");

/// Object IDs and hash functions.
pub const oid = @import("oid.zig");
/// Object types, headers and hashing.
pub const object = @import("object.zig");
/// Commit parser and serializer.
pub const commit = @import("commit.zig");
/// Tree iterator, ordering and validation.
pub const tree = @import("tree.zig");
/// Annotated tag parser and serializer.
pub const tag = @import("tag.zig");
/// zlib inflate helpers with trailer verification.
pub const zlib = @import("zlib.zig");
/// Loose object read and write.
pub const loose = @import("loose.zig");
/// Whole-file read-only maps.
pub const mapped = @import("mapped.zig");
/// Pack index v2.
pub const idx = @import("pack/idx.zig");
/// Packfile reading.
pub const pack = @import("pack/pack.zig");
/// Delta encoding and application.
pub const delta = @import("pack/delta.zig");
/// Delta-base cache.
pub const cache = @import("pack/cache.zig");
/// Reverse indexes.
pub const rev = @import("pack/rev.zig");
/// Multi-pack-index reader.
pub const midx = @import("pack/midx.zig");
/// Delta compression.
pub const deltify = @import("pack/deltify.zig");
/// Pack writer.
pub const pack_writer = @import("pack/writer.zig");
/// Pack indexer (index-pack).
pub const indexer = @import("pack/indexer.zig");
/// commit-graph reader.
pub const commit_graph = @import("commit_graph.zig");
/// git config files: syntax, scopes, includes, and the in-place writer.
pub const config = @import("config.zig");
/// The index (staging area): versions 2 to 4 and extensions.
pub const index = @import("index/index.zig");
/// An open repository: refs, objects and config together.
pub const repository = @import("repository.zig");
/// See `repository.Repository`.
pub const Repository = repository.Repository;
/// `git status`: staged, unstaged, untracked and ignored files.
pub const status = @import("status.zig");
/// Staging: add, add -u, add -N, partial content, unstage, rm.
pub const stage = @import("stage.zig");
/// `git write-tree`.
pub const write_tree = @import("write_tree.zig");
/// `git commit`.
pub const commit_cmd = @import("commit_cmd.zig");
/// Merge bases, ahead/behind and the log.
pub const revwalk = @import("revwalk.zig");
/// Revision names (`HEAD~2`, `main@{u}`, abbreviated ids, `rev:path`).
pub const revparse = @import("revparse.zig");
/// Switching branches, reset, restore and clean.
pub const checkout = @import("checkout.zig");
/// Branches, upstreams and tags.
pub const branch = @import("branch.zig");
/// Remotes and the network: refspecs, `git remote`, transports, the wire
/// protocol, fetch and push.
pub const remote = struct {
    pub const refspec = @import("remote/refspec.zig");
    pub const config = @import("remote/remote.zig");
    pub const transport = @import("remote/transport.zig");
    pub const protocol = @import("remote/protocol.zig");
    pub const objects = @import("remote/objects.zig");
    pub const fetch = @import("remote/fetch.zig");
    pub const push = @import("remote/push.zig");
    pub const credential = @import("remote/credential.zig");
    pub const http = @import("remote/http.zig");
    pub const connect = @import("remote/connect.zig");
};
/// The native SSH-2 client for `ssh://` and scp-like remotes.
pub const ssh = struct {
    pub const wire = @import("ssh/wire.zig");
    pub const cipher = @import("ssh/cipher.zig");
    pub const pubkey = @import("ssh/pubkey.zig");
    pub const keys = @import("ssh/keys.zig");
    pub const agent = @import("ssh/agent.zig");
    pub const known_hosts = @import("ssh/known_hosts.zig");
    pub const config = @import("ssh/config.zig");
    pub const url = @import("ssh/url.zig");
    pub const client = @import("ssh/client.zig");
    pub const session = @import("ssh/session.zig");
};
/// SSH signatures for commits and tags (`gpg.format = ssh`).
pub const sign = struct {
    pub const sshsig = @import("sign/sshsig.zig");
    pub const allowed_signers = @import("sign/allowed_signers.zig");
    pub const embed = @import("sign/embed.zig");
    pub const signing = @import("sign/signing.zig");
};
/// Repository discovery and reading files at HEAD.
pub const worktree = @import("worktree.zig");
/// Ref names, locks, packed-refs, reflogs, the ref store and transactions.
pub const refs = struct {
    /// Refname validation.
    pub const refname = @import("refs/refname.zig");
    /// Lockfile protocol.
    pub const lock = @import("refs/lock.zig");
    /// packed-refs.
    pub const packed_refs = @import("refs/packed.zig");
    /// Reflogs.
    pub const reflog = @import("refs/reflog.zig");
    /// The ref store.
    pub const store = @import("refs/refs.zig");
    /// Ref transactions.
    pub const transaction = @import("refs/transaction.zig");
    /// See `store.RefStore`.
    pub const RefStore = store.RefStore;
    /// See `store.RefValue`.
    pub const RefValue = store.RefValue;
    /// See `refname.checkRefFormat`.
    pub const checkRefFormat = refname.checkRefFormat;
};
/// The object database.
pub const odb = @import("odb.zig");
/// Wire protocol framing: pkt-lines, sidebands and capabilities.
pub const proto = struct {
    /// pkt-line reader and writer.
    pub const pktline = @import("proto/pktline.zig");
    /// Sideband demultiplexing and progress parsing.
    pub const sideband = @import("proto/sideband.zig");
    /// v0 and v2 capability lists.
    pub const caps = @import("proto/caps.zig");
    /// See `pktline.PktReader`.
    pub const PktReader = pktline.PktReader;
    /// See `pktline.PktWriter`.
    pub const PktWriter = pktline.PktWriter;
    /// See `sideband.Sideband`.
    pub const Sideband = sideband.Sideband;
    /// See `caps.Caps`.
    pub const Caps = caps.Caps;
};

/// See `oid.Oid`.
pub const Oid = oid.Oid;
/// See `oid.ObjectFormat`.
pub const ObjectFormat = oid.ObjectFormat;
/// See `object.ObjectType`.
pub const ObjectType = object.ObjectType;
/// See `object.Object`.
pub const Object = object.Object;
/// See `odb.Odb`.
pub const Odb = odb.Odb;
/// See `object.hashObject`.
pub const hashObject = object.hashObject;

test {
    std.testing.refAllDecls(@This());
    _ = @import("object_test.zig");
    _ = @import("refs/refs_test.zig");
    _ = @import("status_test.zig");
    _ = @import("ops_test.zig");
    _ = @import("remote/remote_test.zig");
    _ = @import("remote/refspec.zig");
    _ = @import("remote/http_test.zig");
    _ = @import("remote/connect.zig");
    _ = @import("ssh/ssh_test.zig");
    std.testing.refAllDecls(ssh);
    _ = @import("sign/sign_test.zig");
    std.testing.refAllDecls(sign);
    _ = @import("proto/pktline_test.zig");
    _ = @import("proto/fuzz_git_pktline.zig");
    std.testing.refAllDecls(refs);
    std.testing.refAllDecls(proto);
}
