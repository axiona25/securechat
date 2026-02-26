import uuid
from django.test import TestCase
from django.contrib.auth import get_user_model
from rest_framework.test import APIClient
from rest_framework import status
from .models import (
    Channel, ChannelCategory, ChannelMember, ChannelPost,
    Poll, PollOption, PollVote, PostReaction, PostComment, PostView,
)

User = get_user_model()


class ChannelTestCase(TestCase):

    def setUp(self):
        self.client = APIClient()
        self.owner = User.objects.create_user(
            username='owner', email='owner@test.com', password='TestPass123!'
        )
        self.admin_user = User.objects.create_user(
            username='admin1', email='admin1@test.com', password='TestPass123!'
        )
        self.subscriber = User.objects.create_user(
            username='sub1', email='sub1@test.com', password='TestPass123!'
        )
        self.outsider = User.objects.create_user(
            username='outsider', email='outsider@test.com', password='TestPass123!'
        )
        self.category = ChannelCategory.objects.create(name='Tech', slug='tech')

    def _auth(self, user):
        self.client.force_authenticate(user=user)

    def _create_channel(self, **kwargs):
        defaults = {
            'owner': self.owner,
            'name': 'Test Channel',
            'username': f'test_{uuid.uuid4().hex[:8]}',
            'channel_type': Channel.ChannelType.PUBLIC,
            'category': self.category,
        }
        defaults.update(kwargs)
        channel = Channel.objects.create(**defaults)
        ChannelMember.objects.create(
            channel=channel, user=self.owner, role=ChannelMember.Role.OWNER
        )
        channel.subscriber_count = 1
        channel.save(update_fields=['subscriber_count'])
        return channel

    def _results(self, resp):
        """DRF pagination: results key for list views."""
        if isinstance(resp.data, dict) and 'results' in resp.data:
            return resp.data['results']
        return resp.data if isinstance(resp.data, list) else []

    # ─── Channel CRUD ───

    def test_create_channel(self):
        self._auth(self.owner)
        resp = self.client.post('/api/channels/', {
            'name': 'My Channel',
            'username': 'mychannel',
            'channel_type': 'public',
            'category': self.category.id,
        })
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)
        self.assertTrue(Channel.objects.filter(username='mychannel').exists())

    def test_list_channels(self):
        self._create_channel(username='ch_list1')
        self._create_channel(username='ch_list2')
        self._auth(self.subscriber)
        resp = self.client.get('/api/channels/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        results = self._results(resp)
        self.assertGreaterEqual(len(results), 2)

    def test_channel_detail(self):
        ch = self._create_channel(username='ch_detail')
        self._auth(self.subscriber)
        resp = self.client.get(f'/api/channels/{ch.id}/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data['username'], 'ch_detail')

    def test_update_channel_owner(self):
        ch = self._create_channel(username='ch_update')
        self._auth(self.owner)
        resp = self.client.patch(f'/api/channels/{ch.id}/', {'name': 'Updated'})
        self.assertEqual(resp.status_code, status.HTTP_200_OK)

    def test_update_channel_denied_for_subscriber(self):
        ch = self._create_channel(username='ch_no_update')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.patch(f'/api/channels/{ch.id}/', {'name': 'Hacked'})
        self.assertEqual(resp.status_code, status.HTTP_403_FORBIDDEN)

    def test_delete_channel_soft(self):
        ch = self._create_channel(username='ch_delete')
        self._auth(self.owner)
        resp = self.client.delete(f'/api/channels/{ch.id}/')
        self.assertEqual(resp.status_code, status.HTTP_204_NO_CONTENT)
        ch.refresh_from_db()
        self.assertFalse(ch.is_active)

    # ─── Subscribe / Unsubscribe ───

    def test_subscribe(self):
        ch = self._create_channel(username='ch_sub')
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/subscribe/')
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)
        self.assertTrue(ChannelMember.objects.filter(channel=ch, user=self.subscriber).exists())

    def test_unsubscribe(self):
        ch = self._create_channel(username='ch_unsub')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/unsubscribe/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertFalse(ChannelMember.objects.filter(channel=ch, user=self.subscriber).exists())

    def test_owner_cannot_unsubscribe(self):
        ch = self._create_channel(username='ch_owner_unsub')
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/unsubscribe/')
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)

    # ─── Join by invite ───

    def test_join_by_invite(self):
        ch = self._create_channel(username='ch_invite')
        self._auth(self.outsider)
        resp = self.client.post(f'/api/channels/join/{ch.invite_code}/')
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)

    # ─── Members management ───

    def test_promote_and_demote(self):
        ch = self._create_channel(username='ch_promote')
        ChannelMember.objects.create(
            channel=ch, user=self.admin_user, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/promote/', {'user_id': self.admin_user.id})
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        m = ChannelMember.objects.get(channel=ch, user=self.admin_user)
        self.assertEqual(m.role, ChannelMember.Role.ADMIN)

        resp = self.client.post(f'/api/channels/{ch.id}/demote/', {'user_id': self.admin_user.id})
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        m.refresh_from_db()
        self.assertEqual(m.role, ChannelMember.Role.SUBSCRIBER)

    def test_ban_and_unban(self):
        ch = self._create_channel(username='ch_ban')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/ban/', {'user_id': self.subscriber.id})
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        m = ChannelMember.objects.get(channel=ch, user=self.subscriber)
        self.assertTrue(m.is_banned)

        resp = self.client.post(f'/api/channels/{ch.id}/unban/', {'user_id': self.subscriber.id})
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        m.refresh_from_db()
        self.assertFalse(m.is_banned)

    def test_banned_user_cannot_subscribe(self):
        ch = self._create_channel(username='ch_ban_sub')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER, is_banned=True
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/subscribe/')
        self.assertEqual(resp.status_code, status.HTTP_403_FORBIDDEN)

    # ─── Mute ───

    def test_mute_toggle(self):
        ch = self._create_channel(username='ch_mute')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/mute/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertTrue(resp.data['is_muted'])
        resp = self.client.post(f'/api/channels/{ch.id}/mute/')
        self.assertFalse(resp.data['is_muted'])

    # ─── Posts ───

    def test_create_text_post(self):
        ch = self._create_channel(username='ch_post')
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/create/', {
            'post_type': 'text',
            'text': 'Hello broadcast!',
        })
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)
        self.assertEqual(resp.data['text'], 'Hello broadcast!')

    def test_subscriber_cannot_post(self):
        ch = self._create_channel(username='ch_nopost')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/create/', {
            'post_type': 'text',
            'text': 'I should not be able to post',
        })
        self.assertEqual(resp.status_code, status.HTTP_403_FORBIDDEN)

    def test_list_posts(self):
        ch = self._create_channel(username='ch_listposts')
        ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='Post 1'
        )
        ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='Post 2'
        )
        self._auth(self.subscriber)
        resp = self.client.get(f'/api/channels/{ch.id}/posts/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        results = self._results(resp)
        self.assertEqual(len(results), 2)

    def test_pin_post(self):
        ch = self._create_channel(username='ch_pin')
        post = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='Pin me'
        )
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/{post.id}/pin/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertTrue(resp.data['is_pinned'])

    def test_pin_limit(self):
        ch = self._create_channel(username='ch_pinlimit')
        for i in range(5):
            ChannelPost.objects.create(
                channel=ch, author=self.owner, post_type='text',
                text=f'Pinned {i}', is_pinned=True
            )
        extra = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='Too many'
        )
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/{extra.id}/pin/')
        self.assertEqual(resp.status_code, status.HTTP_400_BAD_REQUEST)

    # ─── Reactions ───

    def test_react_toggle(self):
        ch = self._create_channel(username='ch_react')
        post = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='React test'
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/{post.id}/react/', {'emoji': '👍'})
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)
        self.assertEqual(resp.data['action'], 'added')

        resp = self.client.post(f'/api/channels/{ch.id}/posts/{post.id}/react/', {'emoji': '👍'})
        self.assertEqual(resp.data['action'], 'removed')

    # ─── Comments ───

    def test_comment_on_post(self):
        ch = self._create_channel(username='ch_comment', comments_enabled=True)
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        post = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='Comment me'
        )
        self._auth(self.subscriber)
        resp = self.client.post(
            f'/api/channels/{ch.id}/posts/{post.id}/comments/',
            {'text': 'Great post!'}
        )
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)

    def test_comment_disabled(self):
        ch = self._create_channel(username='ch_nocomment', comments_enabled=False)
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        post = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='No comments'
        )
        self._auth(self.subscriber)
        resp = self.client.post(
            f'/api/channels/{ch.id}/posts/{post.id}/comments/',
            {'text': 'Nope'}
        )
        self.assertEqual(resp.status_code, status.HTTP_403_FORBIDDEN)

    # ─── Polls ───

    def test_create_poll_and_vote(self):
        ch = self._create_channel(username='ch_poll')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.owner)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/create/', {
            'post_type': 'poll',
            'text': '',
            'poll_question': 'Favorite color?',
            'poll_options': ['Red', 'Blue', 'Green'],
            'poll_is_anonymous': True,
            'poll_allows_multiple': False,
        }, format='json')
        self.assertEqual(resp.status_code, status.HTTP_201_CREATED)
        post_id = resp.data['id']
        poll = Poll.objects.get(post_id=post_id)
        options = list(poll.options.order_by('order'))
        self.assertEqual(len(options), 3)

        # Vote
        self._auth(self.subscriber)
        resp = self.client.post(
            f'/api/channels/{ch.id}/posts/{post_id}/vote/',
            {'option_ids': [str(options[0].id)]},
            format='json'
        )
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data['total_votes'], 1)

    # ─── Stats ───

    def test_stats(self):
        ch = self._create_channel(username='ch_stats')
        ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='S1', view_count=10
        )
        self._auth(self.owner)
        resp = self.client.get(f'/api/channels/{ch.id}/stats/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertEqual(resp.data['total_posts'], 1)
        self.assertEqual(resp.data['total_views'], 10)

    def test_stats_denied_for_subscriber(self):
        ch = self._create_channel(username='ch_stats_deny')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.get(f'/api/channels/{ch.id}/stats/')
        self.assertEqual(resp.status_code, status.HTTP_403_FORBIDDEN)

    # ─── View registration ───

    def test_post_view_register(self):
        ch = self._create_channel(username='ch_view')
        post = ChannelPost.objects.create(
            channel=ch, author=self.owner, post_type='text', text='View me'
        )
        self._auth(self.subscriber)
        resp = self.client.post(f'/api/channels/{ch.id}/posts/{post.id}/view/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        post.refresh_from_db()
        self.assertEqual(post.view_count, 1)

        # Duplicate view
        resp = self.client.post(f'/api/channels/{ch.id}/posts/{post.id}/view/')
        post.refresh_from_db()
        self.assertEqual(post.view_count, 1)

    # ─── Categories ───

    def test_list_categories(self):
        self._auth(self.subscriber)
        resp = self.client.get('/api/channels/categories/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        self.assertGreaterEqual(len(resp.data), 1)

    # ─── My channels ───

    def test_my_channels(self):
        ch = self._create_channel(username='ch_mine')
        ChannelMember.objects.create(
            channel=ch, user=self.subscriber, role=ChannelMember.Role.SUBSCRIBER
        )
        self._auth(self.subscriber)
        resp = self.client.get('/api/channels/me/')
        self.assertEqual(resp.status_code, status.HTTP_200_OK)
        results = self._results(resp)
        usernames = [c['username'] for c in results]
        self.assertIn('ch_mine', usernames)
