from django.contrib import admin
from .models import (
    ChannelCategory, Channel, ChannelMember, ChannelPost,
    PostReaction, PostComment, PostView, Poll, PollOption, PollVote,
)


@admin.register(ChannelCategory)
class ChannelCategoryAdmin(admin.ModelAdmin):
    list_display = ['name', 'slug', 'order', 'created_at']
    prepopulated_fields = {'slug': ('name',)}
    ordering = ['order']


class ChannelMemberInline(admin.TabularInline):
    model = ChannelMember
    extra = 0
    readonly_fields = ['joined_at']
    raw_id_fields = ['user']


@admin.register(Channel)
class ChannelAdmin(admin.ModelAdmin):
    list_display = ['username', 'name', 'owner', 'channel_type', 'subscriber_count', 'is_active', 'created_at']
    list_filter = ['channel_type', 'is_active', 'is_verified', 'category']
    search_fields = ['name', 'username', 'description']
    raw_id_fields = ['owner', 'category']
    readonly_fields = ['id', 'invite_code', 'subscriber_count', 'created_at', 'updated_at']
    inlines = [ChannelMemberInline]


@admin.register(ChannelMember)
class ChannelMemberAdmin(admin.ModelAdmin):
    list_display = ['user', 'channel', 'role', 'is_muted', 'is_banned', 'joined_at']
    list_filter = ['role', 'is_banned', 'is_muted']
    raw_id_fields = ['user', 'channel']


class PollOptionInline(admin.TabularInline):
    model = PollOption
    extra = 0


@admin.register(ChannelPost)
class ChannelPostAdmin(admin.ModelAdmin):
    list_display = ['id', 'channel', 'author', 'post_type', 'is_pinned', 'is_published', 'view_count', 'created_at']
    list_filter = ['post_type', 'is_pinned', 'is_published', 'is_scheduled']
    raw_id_fields = ['channel', 'author']
    readonly_fields = ['id', 'view_count', 'reaction_count', 'comment_count', 'created_at', 'updated_at']


@admin.register(Poll)
class PollAdmin(admin.ModelAdmin):
    list_display = ['question', 'post', 'is_anonymous', 'allows_multiple_answers', 'total_votes', 'expires_at']
    raw_id_fields = ['post']
    inlines = [PollOptionInline]


@admin.register(PollOption)
class PollOptionAdmin(admin.ModelAdmin):
    list_display = ['text', 'poll', 'vote_count', 'order']
    raw_id_fields = ['poll']


@admin.register(PollVote)
class PollVoteAdmin(admin.ModelAdmin):
    list_display = ['user', 'poll', 'option', 'voted_at']
    raw_id_fields = ['user', 'poll', 'option']


@admin.register(PostReaction)
class PostReactionAdmin(admin.ModelAdmin):
    list_display = ['user', 'post', 'emoji', 'created_at']
    raw_id_fields = ['user', 'post']


@admin.register(PostComment)
class PostCommentAdmin(admin.ModelAdmin):
    list_display = ['author', 'post', 'text', 'parent', 'created_at']
    raw_id_fields = ['author', 'post', 'parent']


@admin.register(PostView)
class PostViewAdmin(admin.ModelAdmin):
    list_display = ['user', 'post', 'viewed_at']
    raw_id_fields = ['user', 'post']
